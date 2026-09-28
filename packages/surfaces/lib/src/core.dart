import 'dart:convert';
import 'dart:typed_data';

import 'ops.dart';

/// The two functions an app's Rust core exposes on every target (see
/// `surfaces_core::abi`): JSON in, JSON Envelope or bytes out, synchronous.
abstract class CoreBinding {
  /// What runs the core, for display (`flutter_rust_bridge`, `wasm`).
  String get runtime;

  String callJson(String request);

  /// First byte 0: the answer follows. First byte 1: an error Envelope.
  Uint8List callBytes(String request);
}

/// A [CoreBinding] from two functions, such as the app's
/// flutter_rust_bridge `core_call` and `core_bytes`.
class FunctionCoreBinding implements CoreBinding {
  const FunctionCoreBinding({
    required String Function(String) call,
    required Uint8List Function(String) bytes,
    this.runtime = 'flutter_rust_bridge',
  }) : _call = call,
       _bytes = bytes;

  final String Function(String) _call;
  final Uint8List Function(String) _bytes;

  @override
  final String runtime;

  @override
  String callJson(String request) => _call(request);

  @override
  Uint8List callBytes(String request) => _bytes(request);
}

/// The app's Rust core: fast, pure work that runs in the app's own process
/// (flutter_rust_bridge natively, a plain wasm module on the web). Calls are
/// synchronous and run on the UI thread; slow or privileged work belongs in
/// [Ops].
class Core {
  Core(CoreBinding binding) : _binding = binding;

  Core.unavailable([this.why = 'No Rust core on this host']) : _binding = null;

  final CoreBinding? _binding;
  String why = '';

  bool get available => _binding != null;
  String get runtime => _binding?.runtime ?? 'none';

  CoreBinding _require(String op) {
    final binding = _binding;
    if (binding == null) throw OpsException('unavailable', '$op: $why');
    return binding;
  }

  static String _request(String op, Object? input) =>
      jsonEncode({'op': op, 'input': input});

  /// Runs [op] and returns its JSON result.
  Object? call(String op, [Object? input]) {
    final answer = jsonDecode(_require(op).callJson(_request(op, input)));
    if (answer is Map && answer.containsKey('ok')) return answer['ok'];
    final error = (answer as Map)['error'] as Map;
    throw OpsException('${error['code']}', '${error['message']}');
  }

  /// Runs [op] for a binary answer (pixels, file contents).
  Uint8List bytes(String op, [Object? input]) {
    final answer = _require(op).callBytes(_request(op, input));
    if (answer.isNotEmpty && answer[0] == 0) {
      return Uint8List.sublistView(answer, 1);
    }
    final envelope = answer.isEmpty ? const {} : jsonDecode(utf8.decode(answer.sublist(1)));
    final error = (envelope as Map)['error'] as Map? ?? const {};
    throw OpsException('${error['code'] ?? 'core'}', '${error['message'] ?? 'empty answer'}');
  }
}
