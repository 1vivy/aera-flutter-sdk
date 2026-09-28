import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'run.dart';

/// Bridge profiles `surfaces serve` can fake: WebUI X, the KernelSU WebUI
/// bridge with every optional method, the bare bridge, and a plain browser.
const tiers = ['webuix', 'webui', 'webui-min', 'browser'];

/// Serves a web build the way a root manager's WebUI does, with a fake host
/// bridge for [tier]. Commands run on this PC inside a sandboxed fake device
/// root (`.dart_tool/surfaces/device`), where `/data/adb`, `/data/local/tmp`
/// and `/sdcard` are folders, or on a phone over `adb shell su -c` with
/// [adb].
class DevServer {
  DevServer({
    required this.app,
    required this.webroot,
    required this.tier,
    this.port = 8080,
    this.adb = false,
    this.dark = true,
    this.panel = true,
    this.hostWorker,
  });

  final AppConfig app;
  final String webroot;
  final String tier;
  final int port;
  final bool adb;
  final bool dark;
  final bool panel;

  /// The worker built for this PC, installed into the fake module.
  final String? hostWorker;

  late final String sandbox = p.join(app.root, '.dart_tool', 'surfaces', 'device');
  String get moduleDir => '/data/adb/modules/${app.id}';

  HttpServer? _server;
  late String _fakeHost;

  Future<int> start() async {
    _fakeHost = File(await asset('webui/fake_host.js')).readAsStringSync();
    if (!adb) _prepareSandbox();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_handle);
    return server.port;
  }

  Future<void> close() async => _server?.close(force: true);

  void _prepareSandbox() {
    for (final dir in ['data/adb/modules/${app.id}/bin', 'data/local/tmp', 'sdcard/Download']) {
      Directory(p.join(sandbox, dir)).createSync(recursive: true);
    }
    final worker = hostWorker;
    if (worker != null && File(worker).existsSync()) {
      final target = p.join(sandbox, 'data/adb/modules/${app.id}/bin', app.worker);
      File(worker).copySync(target);
      Process.runSync('chmod', ['755', target]);
    }
  }

  /// Maps device paths into the sandbox.
  String _rewrite(String command) => command
      .replaceAll('/data/adb/', '$sandbox/data/adb/')
      .replaceAll('/data/local/tmp/', '$sandbox/data/local/tmp/')
      .replaceAll('/sdcard/', '$sandbox/sdcard/');

  Future<Map<String, Object>> _exec(String command) async {
    // A few Android commands, faked on a PC.
    if (!adb && command.trim().startsWith('pm list packages')) {
      return {
        'code': 0,
        'stdout': 'package:com.android.chrome\npackage:com.termux\npackage:org.fdroid.fdroid',
        'stderr': '',
      };
    }
    final ProcessResult result;
    try {
      result = adb
          ? await Process.run('adb', ['shell', 'su', '-c', "'${command.replaceAll("'", r"'\''")}'"])
              .timeout(const Duration(seconds: 60))
          : await Process.run('sh', ['-c', _rewrite(command)], workingDirectory: sandbox)
              .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      return {'code': 124, 'stdout': '', 'stderr': 'timed out'};
    }
    // Hosts join output lines with "\n", so a trailing newline is lost.
    String trim(Object? text) => '$text'.replaceFirst(RegExp(r'\n$'), '');
    return {'code': result.exitCode, 'stdout': trim(result.stdout), 'stderr': trim(result.stderr)};
  }

  bool get _ksuFamily => tier != 'browser';
  bool get _insets => tier == 'webuix' || tier == 'webui';
  bool get _colors => tier == 'webuix' || tier == 'webui';

  static const _insetsCss = ':root {\n'
      '  --safe-area-inset-top: 32px; --safe-area-inset-bottom: 24px;\n'
      '  --safe-area-inset-left: 0px; --safe-area-inset-right: 0px;\n'
      '  --window-inset-top: 32px; --window-inset-bottom: 24px;\n'
      '  --window-inset-left: 0px; --window-inset-right: 0px;\n'
      '}\n';

  String _colorsCss() => dark
      ? ':root { --primary: #ffb4a8; --onPrimary: #561e16; --primaryContainer: #73342a; '
            '--onPrimaryContainer: #ffdad4; --secondary: #e7bdb6; --onSecondary: #442925; '
            '--tertiary: #dec48c; --surface: #1a1110; --onSurface: #f1dfdc; '
            '--surfaceContainer: #271d1c; --surfaceContainerHigh: #322826; '
            '--onSurfaceVariant: #d8c2be; --outline: #a08c89; --error: #ffb4ab; }\n'
      : ':root { --primary: #904a3f; --onPrimary: #ffffff; --primaryContainer: #ffdad4; '
            '--onPrimaryContainer: #3a0905; --secondary: #775651; --onSecondary: #ffffff; '
            '--tertiary: #705c2e; --surface: #fff8f6; --onSurface: #231918; '
            '--surfaceContainer: #fceae7; --surfaceContainerHigh: #f7e4e1; '
            '--onSurfaceVariant: #534341; --outline: #857370; --error: #ba1a1a; }\n';

  String _inject(String html) {
    if (!_ksuFamily) return html;
    final config = jsonEncode({
      'tier': tier,
      'moduleId': app.id,
      'moduleName': app.name,
      'moduleDir': moduleDir,
      'version': app.version,
      'dark': dark,
      'panel': panel,
      'userAgent': 'Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/140.0.0.0 Mobile Safari/537.36',
    });
    final script = '<script>window.__SURFACES_FAKE__=$config;\n$_fakeHost</script>';
    final head = html.indexOf(RegExp(r'<head[^>]*>'));
    if (head < 0) return '$script$html';
    final end = html.indexOf('>', head) + 1;
    return html.substring(0, end) + script + html.substring(end);
  }

  static const _types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript',
    '.mjs': 'text/javascript',
    '.wasm': 'application/wasm',
    '.json': 'application/json',
    '.css': 'text/css',
    '.png': 'image/png',
    '.svg': 'image/svg+xml',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.woff2': 'font/woff2',
  };

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = Uri.decodeComponent(request.uri.path);
    try {
      if (path == '/__surfaces/exec' && request.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final result = await _exec('${body['cmd']}');
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(result));
        return;
      }
      if (path == '/internal/insets.css' && _insets) {
        response.headers.contentType = ContentType('text', 'css');
        response.write(_insetsCss);
        return;
      }
      if (path == '/internal/colors.css' && _colors) {
        response.headers.contentType = ContentType('text', 'css');
        response.write(_colorsCss());
        return;
      }
      var relative = path == '/' ? 'index.html' : path.substring(1);
      if (relative.contains('..')) relative = 'index.html';
      final file = File(p.join(webroot, relative));
      if (!file.existsSync()) {
        // KernelSU answers a missing file with an empty 200 (typed by its
        // extension); browsers 404.
        response.statusCode = _ksuFamily ? HttpStatus.ok : HttpStatus.notFound;
        if (_ksuFamily) {
          response.headers.set('content-type', _types[p.extension(relative)] ?? 'text/plain');
        }
        return;
      }
      final type = _types[p.extension(file.path)] ?? 'application/octet-stream';
      response.headers.set('content-type', type);
      response.headers.set('cache-control', 'no-store');
      if (relative == 'index.html') {
        response.write(_inject(file.readAsStringSync()));
      } else {
        await response.addStream(file.openRead());
      }
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write('$error');
    } finally {
      await response.close();
    }
  }
}
