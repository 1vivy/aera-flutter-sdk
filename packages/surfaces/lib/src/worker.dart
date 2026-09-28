import 'dart:convert';

import 'ops.dart';
import 'services.dart';
import 'shell.dart';

/// Ops over a worker binary run through the host's shell: the WebUI
/// transport. The worker is the app's `surfaces_ops::worker::main`.
///
/// Every call is one short command (`worker call`, `start`, `poll`,
/// `cancel`), because on most WebUI hosts a command freezes the page until
/// it ends. Long work runs as a detached job the Dart side polls.
class WorkerTransport implements OpsTransport {
  WorkerTransport({
    required this.shell,
    required this.worker,
    required this.stateDir,
  });

  final SurfaceShell shell;

  /// The worker's full path, such as `/data/adb/modules/my_app/bin/worker`.
  final String worker;

  /// Where jobs keep their status files.
  final String stateDir;

  @override
  String get name => 'worker over ksu.exec';

  @override
  bool get supportsJobs => true;

  static String encode(String request) =>
      base64Url.encode(utf8.encode(request)).replaceAll('=', '');

  Future<String> _run(List<String> args) async {
    final result = await shell.exec(
      shellLine([worker, '--state', stateDir, ...args]),
    );
    final lines = result.stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      final why = result.stderr.trim().isEmpty
          ? 'exit ${result.code}, no output'
          : result.stderr.trim();
      return jsonEncode({
        'error': {'code': 'transport', 'message': 'Worker failed: $why'},
      });
    }
    return lines.last;
  }

  @override
  Future<String> call(String request) => _run(['call', encode(request)]);

  @override
  Future<String> start(String request) => _run(['start', encode(request)]);

  @override
  Future<String> poll(String id) => _run(['poll', id]);

  @override
  Future<String> cancel(String id) => _run(['cancel', id]);

  /// Asks the worker who it is: `{"ok": {"protocol": 1, ...}}`.
  Future<String> hello() => _run(['hello']);
}
