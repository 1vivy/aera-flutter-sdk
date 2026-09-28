import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:surfaces_cli/surfaces_cli.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'surfaces',
    'Build a surfaces app for every target, and try WebUI builds against a fake root manager.',
  )
    ..addCommand(BuildCommand())
    ..addCommand(ServeCommand())
    ..addCommand(SimCommand())
    ..addCommand(DoctorCommand());
  try {
    await runner.run(arguments);
  } on UsageException catch (error) {
    stderr.writeln(error);
    exit(64);
  } on UsageError catch (error) {
    stderr.writeln('surfaces: $error');
    exit(1);
  }
}

AppConfig _app() => AppConfig.load(Directory.current.path);

class BuildCommand extends Command<void> {
  BuildCommand() {
    argParser.addFlag('wasm', help: 'Web targets: add a dart2wasm/Skwasm build next to the JS one.');
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Build for a target: webui (module zip), web (hosted), aera (.aerap), linux, or all.';

  @override
  String get invocation => 'surfaces build <webui|web|aera|linux|all>';

  @override
  Future<void> run() async {
    final targets = argResults!.rest;
    if (targets.length != 1) usageException('Name one target.');
    final app = _app();
    final wasm = argResults!['wasm'] as bool;
    final outputs = <String>[];
    Future<void> one(String target) async {
      switch (target) {
        case 'webui':
          outputs.add(await buildModule(app, wasm: wasm));
        case 'web':
          outputs.add(await buildHosted(app, wasm: wasm));
        case 'aera':
          await aera(app, ['package']);
          outputs.add(p.join(app.buildDir, 'aera'));
        case 'linux':
          outputs.add(await buildLinux(app));
        default:
          usageException('Unknown target $target');
      }
    }

    if (targets.single == 'all') {
      for (final target in ['webui', 'aera', 'linux', 'web']) {
        await one(target);
      }
    } else {
      await one(targets.single);
    }
    for (final output in outputs) {
      stdout.writeln(p.relative(output, from: app.root));
    }
  }
}

class ServeCommand extends Command<void> {
  ServeCommand() {
    argParser
      ..addOption('host', abbr: 't', allowed: tiers, defaultsTo: 'webuix',
          help: 'Which root manager to pretend to be.')
      ..addOption('port', abbr: 'p', defaultsTo: '8080')
      ..addOption('dir', help: 'The webroot to serve (default: the last webui or web build).')
      ..addFlag('adb', help: 'Run commands on a rooted phone over adb instead of this PC.')
      ..addFlag('light', help: 'Pretend the host is in light mode.')
      ..addFlag('panel', defaultsTo: true, help: 'Show the fake host panel (Back, Pause, Resume, log).')
      ..addFlag('build', defaultsTo: true, help: 'Build the web app and the worker first.');
  }

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Serve the WebUI build in a browser as a KernelSU / WebUI X host would, at any tier of the ladder.';

  @override
  Future<void> run() async {
    final args = argResults!;
    final app = _app();
    var webroot = args['dir'] as String?;
    if (args['build'] as bool) webroot ??= await buildWeb(app, target: 'webui');
    webroot ??= [
      p.join(app.buildDir, 'webui', 'module', 'webroot'),
      p.join(app.buildDir, 'web'),
    ].firstWhere((d) => Directory(d).existsSync(),
        orElse: () => throw UsageError('Nothing built yet; run surfaces build webui'));
    // The fake module's worker, built for this PC.
    final worker = args['adb'] as bool ? null : (await buildWorker(app, ['host']))['host'];
    final server = DevServer(
      app: app,
      webroot: webroot,
      tier: args['host'] as String,
      port: int.parse(args['port'] as String),
      adb: args['adb'] as bool,
      dark: !(args['light'] as bool),
      panel: args['panel'] as bool,
      hostWorker: worker,
    );
    final port = await server.start();
    stdout.writeln('Serving ${p.relative(webroot, from: app.root)} as a ${server.tier} host on http://127.0.0.1:$port/');
    stdout.writeln(server.adb
        ? 'Commands run on the phone (adb shell su -c).'
        : 'Commands run on this PC in ${p.relative(server.sandbox, from: app.root)}.');
    await ProcessSignal.sigint.watch().first;
    await server.close();
  }
}

class SimCommand extends Command<void> {
  // Everything after `sim` goes to aera-host-sim as is.
  @override
  final argParser = ArgParser.allowAnything();

  @override
  String get name => 'sim';

  @override
  String get description => 'Run the app in the AERA simulator on this PC (frames land in build/aera/frames).';

  @override
  String get invocation => 'surfaces sim [aera-host-sim options]';

  @override
  Future<void> run() => aera(_app(), ['sim', ...argResults!.rest]);
}

class DoctorCommand extends Command<void> {
  @override
  String get name => 'doctor';

  @override
  String get description => 'Check the tools each target needs.';

  @override
  Future<void> run() async {
    final checks = {
      'flutter (3.47.5 for AERA kits)': which('flutter'),
      'cargo': which('cargo'),
      'rustup (adds wasm32 and musl targets)': which('rustup'),
      'zip (module zips)': which('zip'),
      'aarch64-linux-gnu-gcc (AERA native library)': which('aarch64-linux-gnu-gcc'),
      'xz (AERA packages)': which('xz'),
      'adb (serve --adb)': which('adb'),
    };
    checks.forEach((tool, ok) => stdout.writeln('${ok ? '✓' : '✗'} $tool'));
  }
}
