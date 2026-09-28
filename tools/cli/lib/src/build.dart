import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'run.dart';

/// Worker builds for the module: Android ABI folder → Rust target. Static
/// musl binaries run on Android as root without the NDK.
const workerTargets = {
  'arm64-v8a': 'aarch64-unknown-linux-musl',
  'x86_64': 'x86_64-unknown-linux-musl',
};

Future<void> _rustTargets(List<String> targets) async {
  if (!which('rustup')) return;
  final installed = (await Process.run('rustup', ['target', 'list', '--installed'])).stdout as String;
  final missing = targets.where((t) => !installed.split('\n').contains(t)).toList();
  if (missing.isNotEmpty) await run('rustup', ['target', 'add', ...missing]);
}

/// `flutter build web` with the settings every WebUI host needs, the Rust
/// core as `core.wasm`, and CanvasKit pruned.
///
/// - `--no-web-resources-cdn`: no host lets the page reach gstatic (WebUI X's
///   default CSP blocks it and KernelSU may be offline).
/// - `--pwa-strategy=none`: no host runs service workers.
/// - `--base-href=/`: hosts serve the module's webroot at the site root.
Future<String> buildWeb(AppConfig app, {required String target, bool wasm = false}) async {
  step('Building Flutter web for $target${wasm ? ' (wasm)' : ''}');
  await run('flutter', [
    'build', 'web', '--release',
    '--no-web-resources-cdn',
    '--pwa-strategy=none',
    '--base-href=/',
    '--dart-define=SURFACES_TARGET=$target',
    if (wasm) '--wasm',
  ], workingDirectory: app.root);
  final web = p.join(app.buildDir, 'web');
  _prune(web, wasm: wasm);
  await buildCoreWasm(app, web);
  return web;
}

void _prune(String web, {required bool wasm}) {
  step('Pruning the web build');
  final canvaskit = Directory(p.join(web, 'canvaskit'));
  if (canvaskit.existsSync()) {
    for (final file in canvaskit.listSync(recursive: true).whereType<File>()) {
      final name = p.basename(file.path);
      final unused = name.endsWith('.symbols') ||
          name.startsWith('wimp.') ||
          // A JS build only ever loads CanvasKit.
          (!wasm && name.startsWith('skwasm'));
      if (unused) file.deleteSync();
    }
    final paragraph = Directory(p.join(canvaskit.path, 'webparagraph'));
    if (paragraph.existsSync()) paragraph.deleteSync(recursive: true);
  }
  for (final name in ['flutter_service_worker.js', 'version.json', 'manifest.json']) {
    final file = File(p.join(web, name));
    if (file.existsSync()) file.deleteSync();
  }
}

/// Builds the core crate for wasm32 and puts it next to the page.
Future<void> buildCoreWasm(AppConfig app, String web) async {
  final crate = app.coreCrate;
  if (crate == null) return;
  step('Building the Rust core for the web ($crate → core.wasm)');
  await _rustTargets(['wasm32-unknown-unknown']);
  await run('cargo', [
    'build', '--release', '-p', crate, '--lib',
    '--target', 'wasm32-unknown-unknown',
  ], workingDirectory: app.rustDir);
  final built = File(p.join(app.rustDir, 'target', 'wasm32-unknown-unknown', 'release', '${crateLib(crate)}.wasm'));
  built.copySync(p.join(web, 'core.wasm'));
}

/// Builds the ops worker for [targets] (Rust target triples); returns the
/// built files by target.
Future<Map<String, String>> buildWorker(AppConfig app, Iterable<String> targets) async {
  final crate = app.workerCrate;
  if (crate == null) return const {};
  final out = <String, String>{};
  final cross = targets.where((t) => t != 'host').toList();
  await _rustTargets(cross);
  for (final target in targets) {
    step('Building the ops worker ($crate, $target)');
    final env = <String, String>{};
    if (target.endsWith('-linux-musl')) {
      // rust-lld links the target's own musl; no cross toolchain needed.
      env['CARGO_TARGET_${target.toUpperCase().replaceAll('-', '_')}_LINKER'] = 'rust-lld';
    }
    await run('cargo', [
      'build', '--release', '-p', crate,
      if (target != 'host') ...['--target', target],
    ], workingDirectory: app.rustDir, environment: env);
    final binary = await _binaryName(app, crate);
    out[target] = target == 'host'
        ? p.join(app.rustDir, 'target', 'release', binary)
        : p.join(app.rustDir, 'target', target, 'release', binary);
  }
  return out;
}

Future<String> _binaryName(AppConfig app, String crate) async {
  // The worker crate's binary target, from Cargo itself.
  final result = await Process.run(
    'cargo', ['metadata', '--no-deps', '--format-version', '1'],
    workingDirectory: app.rustDir,
  );
  if (result.exitCode == 0) {
    final metadata = jsonDecode(result.stdout as String) as Map<String, Object?>;
    for (final package in (metadata['packages'] as List).cast<Map<String, Object?>>()) {
      if (package['name'] != crate) continue;
      for (final target in (package['targets'] as List).cast<Map<String, Object?>>()) {
        if ((target['kind'] as List).contains('bin')) return target['name'] as String;
      }
    }
  }
  return crate;
}

/// Template file for the module: the app's `webui/<name>` if it has one,
/// otherwise the default.
Future<String> _moduleFile(AppConfig app, String name) async {
  final own = File(p.join(app.root, 'webui', name));
  if (own.existsSync()) return own.path;
  return asset('webui/$name');
}

/// The installable KernelSU / APatch / Magisk (WebUI X) module zip.
Future<String> buildModule(AppConfig app, {bool wasm = false}) async {
  final web = await buildWeb(app, target: 'webui', wasm: wasm);
  final workers = await buildWorker(app, workerTargets.values);
  final stage = Directory(p.join(app.buildDir, 'webui', 'module'));
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  step('Staging the module');
  copyTree(web, p.join(stage.path, 'webroot'));
  for (final name in ['module.prop', 'customize.sh', 'config.json']) {
    final text = app.fill(File(await _moduleFile(app, name)).readAsStringSync());
    final target = name == 'config.json' ? p.join(stage.path, 'webroot', name) : p.join(stage.path, name);
    File(target).writeAsStringSync(text);
  }
  // Magisk's installer stub, so WebUI X Portable on Magisk can install it.
  final metaInf = p.join(p.dirname(await asset('webui/module.prop')), 'META-INF');
  copyTree(metaInf, p.join(stage.path, 'META-INF'));
  for (final extra in ['service.sh', 'post-fs-data.sh', 'uninstall.sh', 'action.sh']) {
    final own = File(p.join(app.root, 'webui', extra));
    if (own.existsSync()) own.copySync(p.join(stage.path, extra));
  }
  final icon = File(p.join(app.root, 'webui', 'icon.png'));
  if (icon.existsSync()) icon.copySync(p.join(stage.path, 'webroot', 'icon.png'));
  workerTargets.forEach((abi, target) {
    final built = workers[target];
    if (built == null) return;
    final dir = Directory(p.join(stage.path, 'bin', abi))..createSync(recursive: true);
    File(built).copySync(p.join(dir.path, app.worker));
  });

  final zip = p.join(app.buildDir, 'webui', '${app.id}-${app.version}.zip');
  final file = File(zip);
  if (file.existsSync()) file.deleteSync();
  step('Zipping ${p.relative(zip, from: app.root)}');
  if (!which('zip')) throw UsageError('zip is not installed');
  await run('zip', ['-q', '-r', '-X', zip, '.'], workingDirectory: stage.path);
  return zip;
}

/// A hosted web build: the same app, bottom rung of the WebUI ladder.
Future<String> buildHosted(AppConfig app, {bool wasm = false}) async {
  final web = await buildWeb(app, target: 'web', wasm: wasm);
  final zip = p.join(app.buildDir, '${app.id}-${app.version}-web.zip');
  final file = File(zip);
  if (file.existsSync()) file.deleteSync();
  if (which('zip')) await run('zip', ['-q', '-r', '-X', zip, '.'], workingDirectory: web);
  return web;
}

/// `flutter build linux`, packed as a tarball.
Future<String> buildLinux(AppConfig app) async {
  step('Building for Linux desktop');
  await run('flutter', ['build', 'linux', '--release', '--dart-define=SURFACES_TARGET=linux'],
      workingDirectory: app.root);
  final bundle = p.join(app.buildDir, 'linux', 'x64', 'release', 'bundle');
  final tar = p.join(app.buildDir, '${app.id}-${app.version}-linux-x64.tar.gz');
  await run('tar', ['-czf', tar, '-C', p.dirname(bundle), '--transform', 's,^bundle,${app.id},', 'bundle'],
      workingDirectory: app.root);
  return tar;
}

/// Runs the AERA packer (from aera-flutter-template) for this app.
Future<void> aera(AppConfig app, List<String> arguments) async {
  final script = await asset('aera/aera.sh');
  await run('bash', [script, ...arguments], workingDirectory: app.root, environment: {
    'SURFACES_APP_ROOT': app.root,
    'SURFACES_NATIVE_DIR': p.relative(app.rustDir, from: app.root),
    'SURFACES_NATIVE_CRATE': crateLib(app.nativeCrate ?? 'aera_app_core'),
    'SURFACES_NAME': app.name,
    'SURFACES_VERSION': app.version,
    'SURFACES_DESCRIPTION': app.description,
  });
}
