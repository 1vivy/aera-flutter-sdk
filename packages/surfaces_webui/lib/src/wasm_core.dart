// Loads the app's Rust core as a plain wasm module (see surfaces_core::abi):
// no wasm-bindgen, no threads, no shared memory, so it runs on WebUI hosts
// that cannot be cross-origin isolated.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:surfaces/surfaces.dart';
import 'package:web/web.dart' as web;

extension type _Instantiated._(JSObject _) implements JSObject {
  external JSObject get instance;
}

@JS('WebAssembly.instantiate')
external JSPromise<_Instantiated> _instantiate(
  JSArrayBuffer bytes,
  JSObject imports,
);

class WasmCoreBinding implements CoreBinding {
  WasmCoreBinding._(this._exports);

  final JSObject _exports;

  /// Fetches and instantiates [url]. Null when there is none or it does not
  /// export the surfaces ABI.
  static Future<WasmCoreBinding?> load(String url) async {
    try {
      final response = await web.window.fetch(url.toJS).toDart;
      if (!response.ok) return null;
      final type = response.headers.get('content-type') ?? '';
      // Hosts answer a missing file with an empty 200 or an HTML page.
      if (type.contains('html')) return null;
      final bytes = await response.arrayBuffer().toDart;
      if (bytes.toDart.lengthInBytes < 8) return null;
      final result = await _instantiate(bytes, JSObject()).toDart;
      final exports = result.instance.getProperty<JSObject>('exports'.toJS);
      for (final name in ['surfaces_alloc', 'surfaces_free', 'surfaces_call', 'surfaces_bytes', 'memory']) {
        if (!exports.has(name)) return null;
      }
      return WasmCoreBinding._(exports);
    } catch (_) {
      return null;
    }
  }

  @override
  String get runtime => 'wasm (sync)';

  JSArrayBuffer get _buffer =>
      _exports.getProperty<JSObject>('memory'.toJS).getProperty<JSArrayBuffer>('buffer'.toJS);

  int _number(JSAny? value) => (value as JSNumber).toDartInt;

  Uint8List _invoke(String function, String request) {
    final input = utf8.encode(request);
    final pointer = _number(_exports.callMethod('surfaces_alloc'.toJS, input.length.toJS));
    JSUint8Array(_buffer, pointer, input.length)
        .callMethod<JSAny?>('set'.toJS, input.toJS);
    // Returns a u64 (a JS BigInt): pointer << 32 | length.
    final result = _exports.callMethod<JSAny>(function.toJS, pointer.toJS, input.length.toJS);
    final packed = BigInt.parse(globalContext.callMethod<JSString>('String'.toJS, result).toDart);
    // The core copied the request; the input buffer is ours to free.
    _exports.callMethod<JSAny?>('surfaces_free'.toJS, pointer.toJS, input.length.toJS);
    final resultPointer = (packed >> 32).toInt();
    final length = (packed & BigInt.from(0xffffffff)).toInt();
    final view = JSUint8Array(_buffer, resultPointer, length);
    final out = Uint8List.fromList(view.toDart);
    _exports.callMethod<JSAny?>('surfaces_free'.toJS, resultPointer.toJS, length.toJS);
    return out;
  }

  @override
  String callJson(String request) => utf8.decode(_invoke('surfaces_call', request));

  @override
  Uint8List callBytes(String request) => _invoke('surfaces_bytes', request);
}
