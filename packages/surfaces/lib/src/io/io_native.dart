import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../capability.dart';
import '../host.dart';
import '../services.dart';
import '../shell.dart';
import '../surface.dart';
import 'io_stub.dart' show FallbackServices;

export 'io_stub.dart' show FallbackServices;

/// Text documents as files in [paths]`.appData`.
class IoStorage extends SurfaceStorage {
  IoStorage(this._paths);

  final StoragePaths _paths;

  @override
  StoragePaths get paths => _paths;

  File _file(String name) {
    SurfaceStorage.checkName(name);
    return File('${_paths.appData}/$name');
  }

  @override
  Future<String?> readText(String name) async {
    final file = _file(name);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> writeText(String name, String text) async {
    final file = _file(name);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }

  @override
  Future<void> delete(String name) async {
    final file = _file(name);
    if (await file.exists()) await file.delete();
  }
}

/// Saves into [paths]`.downloads`; no picker.
class IoFiles extends SurfaceFiles {
  IoFiles(this._paths);

  final StoragePaths _paths;

  @override
  Future<String?> save(String name, Uint8List bytes) async {
    final safe = name.replaceAll(RegExp(r'[/\\]'), '_');
    final directory = Directory(_paths.downloads);
    await directory.create(recursive: true);
    final file = File('${directory.path}/$safe');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

/// `sh -c` (or `cmd /c` on Windows).
class IoShell extends SurfaceShell {
  IoShell({this.shell = '/bin/sh'});

  final String shell;

  @override
  Future<ExecResult> exec(
    String command, {
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final watch = Stopwatch()..start();
    try {
      final result = await (Platform.isWindows
              ? Process.run('cmd', ['/c', command],
                  workingDirectory: cwd, environment: env)
              : Process.run(shell, ['-c', command],
                  workingDirectory: cwd,
                  environment: env,
                  stdoutEncoding: utf8,
                  stderrEncoding: utf8))
          .timeout(timeout);
      return ExecResult(
        result.exitCode,
        '${result.stdout}',
        '${result.stderr}',
        elapsed: watch.elapsed,
      );
    } on ProcessException catch (error) {
      return ExecResult.unavailable(error.message);
    }
  }
}

String _home() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.systemTemp.path;

/// The usual per-user folders on this desktop OS.
StoragePaths desktopPaths(String appId) {
  final home = _home();
  final String data;
  if (Platform.isWindows) {
    data = '${Platform.environment['APPDATA'] ?? home}\\$appId';
  } else if (Platform.isMacOS) {
    data = '$home/Library/Application Support/$appId';
  } else {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    data = '${xdg == null || xdg.isEmpty ? '$home/.local/share' : xdg}/$appId';
  }
  return StoragePaths(
    appData: data,
    downloads: Platform.isWindows ? '$home\\Downloads' : '$home/Downloads',
    temp: '${Directory.systemTemp.path}/$appId',
  );
}

FallbackServices createServices(SurfaceConfig config) {
  final mobile = Platform.isAndroid || Platform.isIOS;
  final paths = mobile
      ? StoragePaths(
          appData: '${Directory.systemTemp.parent.path}/files/${config.appId}',
          temp: Directory.systemTemp.path,
        )
      : desktopPaths(config.appId);
  final hasShell = !mobile && (Platform.isWindows || File('/bin/sh').existsSync());
  return FallbackServices(
    kind: mobile ? HostKind.mobile : HostKind.desktop,
    name: switch (Platform.operatingSystem) {
      'linux' => 'Linux desktop',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'android' => 'Android app',
      'ios' => 'iOS app',
      final other => other,
    },
    capabilities: {
      Cap.storagePersistent,
      if (!mobile) Cap.filesSave,
      if (hasShell) ...{Cap.shellExec, Cap.shellExecAsync},
    },
    details: {
      'os': Platform.operatingSystemVersion,
      'dart': Platform.version.split(' ').first,
      'appData': paths.appData,
    },
    storage: IoStorage(paths),
    files: mobile ? null : IoFiles(paths),
    shell: hasShell ? IoShell() : null,
  );
}
