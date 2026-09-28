// The host bridges, read with dart:js_interop. Every host method is looked
// up by name before it is called, because each root manager ships a
// different subset (see research/03-ksu-webui-hosts-source.md).

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:surfaces/surfaces.dart';

JSObject? _global(String name) {
  final value = globalContext.getProperty<JSAny?>(name.toJS);
  if (value == null || value.isUndefinedOrNull) return null;
  if (!value.typeofEquals('object') && !value.typeofEquals('function')) {
    return null;
  }
  return value as JSObject;
}

/// A host object such as `window.ksu`, `window.webui` or `window.$<module>`.
class HostObject {
  HostObject._(this.name, this._object);

  static HostObject? find(String name) {
    final object = _global(name);
    return object == null ? null : HostObject._(name, object);
  }

  final String name;
  final JSObject _object;

  bool has(String method) {
    final value = _object.getProperty<JSAny?>(method.toJS);
    return value != null && value.typeofEquals('function');
  }

  /// Every method name, for host reports.
  List<String> methods() {
    final keys = <String>[];
    // Java objects from addJavascriptInterface enumerate like plain objects.
    final names = globalContext
        .getProperty<JSObject>('Object'.toJS)
        .callMethod<JSArray<JSString>>('keys'.toJS, _object);
    for (final key in names.toDart) {
      final name = key.toDart;
      if (has(name)) keys.add(name);
    }
    if (keys.isEmpty) {
      // Some WebViews hide injected methods from Object.keys.
      for (final name in _knownMethods) {
        if (has(name)) keys.add(name);
      }
    }
    return keys..sort();
  }

  JSAny? call(String method, [List<JSAny?> args = const []]) =>
      _object.callMethodVarArgs<JSAny?>(method.toJS, args);

  String? callString(String method, [List<JSAny?> args = const []]) {
    final value = call(method, args);
    if (value == null || !value.typeofEquals('string')) return null;
    return (value as JSString).toDart;
  }

  bool? callBool(String method, [List<JSAny?> args = const []]) {
    final value = call(method, args);
    if (value == null || !value.typeofEquals('boolean')) return null;
    return (value as JSBoolean).toDart;
  }
}

const _knownMethods = [
  'exec', 'spawn', 'toast', 'fullScreen', 'enableEdgeToEdge', 'enableInsets',
  'moduleInfo', 'listPackages', 'getPackagesInfo', 'exit', 'mmrl', 'execBool',
  'listFile', 'readFile', 'writeFile', 'setRefreshing', 'openFile',
  'isDarkMode', 'setLightStatusBars', 'setLightNavigationBars', 'shareText',
  'getSdk', 'getCurrentRootManager', 'getCurrentApplication',
];

var _sequence = 0;

/// `ksu.exec(cmd, options, callbackName)` as a Future.
///
/// The command is wrapped as `cd <cwd>; export K=V; <cmd>` with every value
/// quoted here, because hosts paste options into the shell unescaped.
Future<ExecResult> ksuExec(
  HostObject ksu,
  String command, {
  String? cwd,
  Map<String, String>? env,
  Duration timeout = const Duration(seconds: 30),
}) {
  final line = StringBuffer();
  if (cwd != null) line.write('cd ${shellQuote(cwd)} || exit 1; ');
  env?.forEach((key, value) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
      throw ArgumentError.value(key, 'env', 'Not a variable name');
    }
    line.write('export $key=${shellQuote(value)}; ');
  });
  line.write(command);

  final completer = Completer<ExecResult>();
  final name = '__surfaces_exec_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
  final watch = Stopwatch()..start();
  late Duration blocked;

  void done(JSAny? code, JSAny? stdout, JSAny? stderr) {
    globalContext.delete(name.toJS);
    if (completer.isCompleted) return;
    completer.complete(ExecResult(
      (code.dartify() as num?)?.toInt() ?? -1,
      (stdout.dartify() as String?) ?? '',
      (stderr.dartify() as String?) ?? '',
      elapsed: watch.elapsed,
      blocked: blocked,
    ));
  }

  globalContext.setProperty(name.toJS, done.toJS);
  try {
    ksu.call('exec', [line.toString().toJS, '{}'.toJS, name.toJS]);
  } catch (error) {
    globalContext.delete(name.toJS);
    return Future.value(ExecResult(-1, '', 'exec failed: $error'));
  }
  blocked = watch.elapsed;
  return completer.future.timeout(timeout, onTimeout: () {
    globalContext.delete(name.toJS);
    return ExecResult(124, '', 'Timed out after ${timeout.inSeconds} s',
        elapsed: watch.elapsed, blocked: blocked);
  });
}

/// Parses a JSON string a host method returned, or null.
Object? parseJson(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
