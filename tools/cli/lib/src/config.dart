import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// An app's `surfaces.yaml`:
///
/// ```yaml
/// id: my_app                 # module id on WebUI; letters, digits, . _ -
/// name: My App
/// version: 0.1.0
/// author: me
/// description: What it does.
/// worker: worker             # the ops worker's name in the module's bin/
/// rust:
///   dir: rust                # the Cargo workspace
///   native: app_native       # flutter_rust_bridge crate (AERA, desktop)
///   core: app_core           # pure core, built to web/core.wasm
///   worker: app_worker       # ops worker binary for WebUI modules
/// ```
///
/// Everything under `rust:` is optional; an app without Rust gets no core
/// and no ops.
class AppConfig {
  AppConfig({
    required this.root,
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.worker,
    required this.rustDir,
    this.nativeCrate,
    this.coreCrate,
    this.workerCrate,
  });

  static AppConfig load(String root) {
    final file = File(p.join(root, 'surfaces.yaml'));
    if (!file.existsSync()) {
      throw UsageError('No surfaces.yaml in $root. Run this from an app made from the surfaces template.');
    }
    final yaml = loadYaml(file.readAsStringSync()) as YamlMap;
    String text(String key, [String fallback = '']) => '${yaml[key] ?? fallback}';
    final rust = (yaml['rust'] as YamlMap?) ?? YamlMap();
    final id = text('id');
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9._-]+$').hasMatch(id)) {
      throw UsageError('surfaces.yaml: id "$id" is not a valid module id');
    }
    return AppConfig(
      root: root,
      id: id,
      name: text('name', id),
      version: text('version', '0.1.0'),
      author: text('author', 'unknown'),
      description: text('description'),
      worker: text('worker', 'worker'),
      rustDir: p.join(root, '${rust['dir'] ?? 'rust'}'),
      nativeCrate: rust['native'] as String?,
      coreCrate: rust['core'] as String?,
      workerCrate: rust['worker'] as String?,
    );
  }

  final String root;
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String worker;
  final String rustDir;
  final String? nativeCrate;
  final String? coreCrate;
  final String? workerCrate;

  /// `1.2.3` → 10203, for module.prop's versionCode.
  int get versionCode {
    final parts = version.split(RegExp(r'[.+-]')).take(3).map((s) => int.tryParse(s) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts[0] * 10000 + parts[1] * 100 + parts[2];
  }

  String get buildDir => p.join(root, 'build');

  /// Replaces `@ID@`, `@NAME@`... in module templates.
  String fill(String template) => template
      .replaceAll('@ID@', id)
      .replaceAll('@NAME@', name)
      .replaceAll('@VERSION@', version)
      .replaceAll('@VERSION_CODE@', '$versionCode')
      .replaceAll('@AUTHOR@', author)
      .replaceAll('@DESCRIPTION@', description.replaceAll('\n', ' '))
      .replaceAll('@WORKER@', worker);
}

class UsageError implements Exception {
  UsageError(this.message);

  final String message;

  @override
  String toString() => message;
}
