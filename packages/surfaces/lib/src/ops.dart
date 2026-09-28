import 'dart:async';
import 'dart:convert';

/// An op failed. [code] is stable (`unavailable`, `not-found`, `cancelled`,
/// `input`, `io`, `unknown-op`, `transport`...); [message] is for people.
class OpsException implements Exception {
  const OpsException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'OpsException($code): $message';
}

/// Carries op documents to the app's handler and back. Each method takes
/// and returns JSON in the shapes of the `surfaces-core` protocol crate.
abstract class OpsTransport {
  /// How ops travel, for display (`worker over ksu.exec`, `in-process`).
  String get name;

  /// Whether [start] runs jobs in the background.
  bool get supportsJobs;

  Future<String> call(String request);
  Future<String> start(String request);
  Future<String> poll(String id);
  Future<String> cancel(String id);
}

/// An [OpsTransport] made of four functions, such as the app's
/// flutter_rust_bridge `ops_call`, `ops_start`, `ops_poll` and `ops_cancel`.
class FunctionOpsTransport implements OpsTransport {
  const FunctionOpsTransport({
    required String Function(String request) call,
    required String Function(String request) start,
    required String Function(String id) poll,
    required String Function(String id) cancel,
    this.name = 'in-process',
    this.supportsJobs = true,
  }) : _call = call,
       _start = start,
       _poll = poll,
       _cancel = cancel;

  final String Function(String) _call;
  final String Function(String) _start;
  final String Function(String) _poll;
  final String Function(String) _cancel;

  @override
  final String name;

  @override
  final bool supportsJobs;

  @override
  Future<String> call(String request) async => _call(request);

  @override
  Future<String> start(String request) async => _start(request);

  @override
  Future<String> poll(String id) async => _poll(id);

  @override
  Future<String> cancel(String id) async => _cancel(id);
}

enum JobState { running, done, failed, cancelled }

/// Where a job stands.
class JobStatus {
  const JobStatus({
    required this.id,
    required this.op,
    required this.state,
    this.progress,
    this.message,
    this.result,
    this.error,
  });

  factory JobStatus.fromJson(Map<String, Object?> json) {
    final error = json['error'];
    return JobStatus(
      id: json['id'] as String? ?? '',
      op: json['op'] as String? ?? '',
      state: JobState.values.firstWhere(
        (s) => s.name == json['state'],
        orElse: () => JobState.failed,
      ),
      progress: (json['progress'] as num?)?.toDouble(),
      message: json['message'] as String?,
      result: json['result'],
      error: error is Map
          ? OpsException('${error['code']}', '${error['message']}')
          : null,
    );
  }

  final String id;
  final String op;
  final JobState state;

  /// 0 to 1, when the job knows.
  final double? progress;
  final String? message;
  final Object? result;
  final OpsException? error;

  bool get finished => state != JobState.running;
}

/// A long op running in the background.
class Job {
  Job._(this._ops, this.id, this.op, JobStatus first) : _latest = first {
    _controller.add(first);
    if (first.finished) {
      _finish(first);
    } else {
      _schedule();
    }
  }

  final Ops _ops;
  final String id;
  final String op;
  final _controller = StreamController<JobStatus>.broadcast();
  final _done = Completer<JobStatus>();
  JobStatus _latest;
  Timer? _timer;

  JobStatus get latest => _latest;

  /// Every status change, ending with the final one.
  Stream<JobStatus> get updates => _controller.stream;

  /// Completes with the final status (done, failed or cancelled).
  Future<JobStatus> get done => _done.future;

  /// Asks the job to stop. It ends as [JobState.cancelled] at its next check.
  Future<void> cancel() async {
    if (_latest.finished) return;
    _decode(await _ops._transport!.cancel(id));
  }

  void _schedule() {
    _timer = Timer(_ops.pollInterval, _poll);
  }

  Future<void> _poll() async {
    try {
      final value = _decode(await _ops._transport!.poll(id));
      _latest = JobStatus.fromJson((value as Map).cast<String, Object?>());
    } on OpsException catch (error) {
      _latest = JobStatus(id: id, op: op, state: JobState.failed, error: error);
    }
    _controller.add(_latest);
    if (_latest.finished) {
      _finish(_latest);
    } else {
      _schedule();
    }
  }

  void _finish(JobStatus status) {
    _timer?.cancel();
    if (!_done.isCompleted) _done.complete(status);
    _controller.close();
  }
}

Object? _decode(String envelope) {
  final Object? json;
  try {
    json = jsonDecode(envelope);
  } on FormatException {
    throw OpsException('transport', 'Not an ops answer: ${_clip(envelope)}');
  }
  if (json is Map && json.containsKey('ok')) return json['ok'];
  if (json is Map && json['error'] is Map) {
    final error = json['error'] as Map;
    throw OpsException('${error['code']}', '${error['message']}');
  }
  throw OpsException('transport', 'Not an ops answer: ${_clip(envelope)}');
}

String _clip(String text) =>
    text.length > 200 ? '${text.substring(0, 200)}…' : text;

/// The app's privileged or long work, defined once in Rust (`surfaces-ops`)
/// and carried by whatever transport this host has: the worker binary over
/// `ksu.exec` on WebUI, in-process on AERA and desktop.
class Ops {
  Ops(OpsTransport transport, {this.pollInterval = const Duration(milliseconds: 250)})
    : _transport = transport;

  /// No ops on this host: every call throws `unavailable`.
  Ops.unavailable([this.why = 'This host has no ops transport'])
    : _transport = null,
      pollInterval = const Duration(milliseconds: 250);

  final OpsTransport? _transport;
  final Duration pollInterval;

  /// Why ops are unavailable, when they are.
  String why = '';

  bool get available => _transport != null;
  bool get supportsJobs => _transport?.supportsJobs ?? false;
  String get transportName => _transport?.name ?? 'none';

  static String _request(String op, Object? input) =>
      jsonEncode({'op': op, 'input': input});

  OpsTransport _require(String op) {
    final transport = _transport;
    if (transport == null) {
      throw OpsException('unavailable', '$op: $why');
    }
    return transport;
  }

  /// Runs [op] to the end and returns its result.
  Future<Object?> call(String op, [Object? input]) async =>
      _decode(await _require(op).call(_request(op, input)));

  /// Starts [op] as a job. Transports without jobs run it to the end first
  /// and return a finished job.
  Future<Job> start(String op, [Object? input]) async {
    final transport = _require(op);
    if (!transport.supportsJobs) {
      try {
        final result = await call(op, input);
        return Job._(this, 'inline', op,
            JobStatus(id: 'inline', op: op, state: JobState.done, progress: 1, result: result));
      } on OpsException catch (error) {
        return Job._(this, 'inline', op,
            JobStatus(id: 'inline', op: op, state: JobState.failed, error: error));
      }
    }
    final started = _decode(await transport.start(_request(op, input)));
    final id = (started as Map)['id'] as String;
    return Job._(this, id, op, JobStatus(id: id, op: op, state: JobState.running));
  }
}
