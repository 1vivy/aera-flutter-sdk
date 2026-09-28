import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'config.dart';

/// Prints a step the way `flutter` does.
void step(String message) => stderr.writeln('• $message');

/// Runs a command, streaming its output; throws when it fails.
Future<void> run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  stderr.writeln('  \$ $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) {
    throw UsageError('$executable exited with $code');
  }
}

/// Whether [executable] is on PATH.
bool which(String executable) =>
    Process.runSync('sh', ['-c', 'command -v $executable']).exitCode == 0;

/// A file shipped in this package's `lib/assets/`.
Future<String> asset(String path) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:surfaces_cli/assets/$path'));
  if (uri == null) throw StateError('Cannot find the surfaces_cli package');
  return uri.toFilePath();
}

/// Copies a directory tree.
void copyTree(String from, String to) {
  for (final entity in Directory(from).listSync(recursive: true, followLinks: false)) {
    final target = p.join(to, p.relative(entity.path, from: from));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

/// A Rust crate's library file stem: `my-core` → `my_core`.
String crateLib(String crate) => crate.replaceAll('-', '_');
