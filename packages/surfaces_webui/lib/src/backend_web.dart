import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:surfaces/surfaces.dart';
import 'package:web/web.dart' as web;

import 'bridge.dart';
import 'wasm_core.dart';

/// Recognises the WebUI ladder and plain browsers.
///
/// | Tier | Host | How it is recognised |
/// | --- | --- | --- |
/// | `webuix` | WebUI X (MMRL, WebUI X Portable) | `ksu.mmrl()` or `window.webui` |
/// | `kernelsu` | KernelSU, SukiSU | `ksu.exit` and `ksu.enableEdgeToEdge` |
/// | `next` | KernelSU Next | `ksu.enableInsets` and `ksu.moduleInfo`, or its file API |
/// | `apatch` | APatch | `ksu.enableInsets` without `ksu.moduleInfo` |
/// | `standalone` | KsuWebUIStandalone, older managers | only `exec`, `spawn`, `toast`, `fullScreen`, `moduleInfo` |
/// | `browser` | anything else | no `window.ksu` |
///
/// Capabilities come from what each host really has, method by method, so
/// a host that gains a method gains the feature.
class WebUiBackend extends SurfaceBackend {
  const WebUiBackend();

  @override
  Future<Surface?> tryCreate(SurfaceConfig config) async {
    final ksu = HostObject.find('ksu');
    final webui = HostObject.find('webui');
    final module = HostObject.find(_moduleGlobal(config.appId));
    final ua = web.window.navigator.userAgent;
    final core = await WasmCoreBinding.load(config.coreWasm);
    if (ksu == null) {
      return _browser(config, ua, core);
    }
    return _webui(config, ksu, webui, module, ua, core);
  }
}

/// WebUI X's name for a module's own global: `$` + id with every character
/// outside `[A-Za-z0-9_]` turned into `_`.
String _moduleGlobal(String appId) =>
    '\$${appId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';

String _engine(String ua) {
  final chrome = RegExp(r'Chrome/(\d+)').firstMatch(ua)?.group(1);
  const wasm = bool.fromEnvironment('dart.tool.dart2wasm');
  final renderer = wasm ? 'Skwasm, dart2wasm' : 'CanvasKit, dart2js';
  return '${chrome == null ? 'Browser' : 'Chrome $chrome'} ($renderer)';
}

({String tier, String name, String version}) _identify(
  HostObject ksu,
  HostObject? webui,
  String ua,
) {
  final webuix = RegExp(r'WebUI X/(\d+)').firstMatch(ua)?.group(1);
  if (ksu.has('mmrl') || webui != null) {
    return (
      tier: 'webuix',
      name: webuix != null ? 'WebUI X Portable' : 'WebUI X (MMRL)',
      version: webuix ?? '',
    );
  }
  if (ksu.has('exit') && ksu.has('enableEdgeToEdge')) {
    return (tier: 'kernelsu', name: 'KernelSU / SukiSU', version: '');
  }
  if (ksu.has('enableInsets') && !ksu.has('moduleInfo')) {
    return (tier: 'apatch', name: 'APatch', version: '');
  }
  if ((ksu.has('enableInsets') && ksu.has('moduleInfo')) ||
      ksu.has('listFile') ||
      ksu.has('readFile')) {
    return (tier: 'next', name: 'KernelSU Next', version: '');
  }
  if (!ksu.has('listPackages')) {
    return (tier: 'standalone', name: 'KsuWebUIStandalone', version: '');
  }
  return (tier: 'kernelsu', name: 'KernelSU-compatible', version: '');
}

Surface _browser(SurfaceConfig config, String ua, WasmCoreBinding? core) {
  final share = _hasNavigatorShare();
  final window = _WebWindow();
  window.start(liveCss: false);
  final lifecycle = _WebLifecycle()..start();
  return Surface(
    info: HostInfo(
      kind: HostKind.browser,
      name: 'Web browser',
      tier: 'browser',
      engine: _engine(ua),
      capabilities: {
        Cap.backHistory,
        Cap.storagePersistent,
        Cap.filesPick,
        Cap.filesSave,
        if (share) Cap.shareNative,
        if (core != null) Cap.coreRust,
      },
      details: {'userAgent': ua},
    ),
    config: config,
    window: window,
    lifecycle: lifecycle,
    storage: _LocalStorage(config.appId),
    files: _WebFiles(null),
    feedback: _WebFeedback(ksu: null, module: null),
    ops: Ops.unavailable('No root worker in a plain browser'),
    core: core == null ? Core.unavailable('No core.wasm in this build') : Core(core),
  );
}

Future<Surface> _webui(
  SurfaceConfig config,
  HostObject ksu,
  HostObject? webui,
  HostObject? module,
  String ua,
  WasmCoreBinding? core,
) async {
  final id = _identify(ksu, webui, ua);
  final webuix = id.tier == 'webuix';
  final info = parseJson(ksu.has('moduleInfo') ? ksu.callString('moduleInfo') : null);
  final moduleDir = info is Map && info['moduleDir'] is String
      ? info['moduleDir'] as String
      : '/data/adb/modules/${config.appId}';

  // Turn on edge-to-edge so the insets mean something. Requesting
  // /internal/insets.css (index.html does) also does it on KernelSU.
  if (ksu.has('enableEdgeToEdge')) {
    ksu.call('enableEdgeToEdge', [true.toJS]);
  } else if (ksu.has('enableInsets')) {
    ksu.call('enableInsets', [true.toJS]);
  }

  final shell = _KsuShell(ksu, async: webuix);
  final paths = StoragePaths(
    appData: '/data/adb/${config.appId}',
    downloads: '/sdcard/Download',
    temp: '/data/local/tmp/${config.appId}',
  );
  final worker = '$moduleDir/bin/${config.workerName}';
  final workerCheck = await shell.exec(
    '[ -x ${shellQuote(worker)} ] && echo yes; '
    'mkdir -p ${shellQuote(paths.temp)} ${shellQuote(paths.appData)}',
  );
  final hasWorker = workerCheck.stdout.trim() == 'yes';

  final window = _WebWindow(ksu: ksu, module: module);
  final insets = id.tier != 'standalone';
  window.start(liveCss: insets);
  final lifecycle = _WebLifecycle()..start();
  final navigation = _WebNavigation(ksu: ksu, webui: webui, window: window);
  final theme = _WebTheme(module);
  final share = (module?.has('shareText') ?? false) || _hasNavigatorShare();
  final canExit =
      (webui?.has('exit') ?? false) || (!webuix && ksu.has('exit'));

  return Surface(
    info: HostInfo(
      kind: HostKind.webui,
      name: id.name,
      tier: id.tier,
      version: id.version,
      engine: _engine(ua),
      capabilities: {
        if (webuix) Cap.backIntercept else Cap.backHistory,
        if (canExit) Cap.exit,
        if (insets) ...{Cap.insets, Cap.insetsLive},
        if (webuix) Cap.keyboardInset,
        if (ksu.has('fullScreen')) Cap.fullscreen,
        if (module?.has('setLightStatusBars') ?? false) Cap.statusBarStyle,
        if (webuix) Cap.lifecycle,
        Cap.storagePersistent,
        Cap.storageRoot,
        Cap.filesPick,
        Cap.filesSave,
        if (ksu.has('toast')) Cap.toastNative,
        if (share) Cap.shareNative,
        if (theme.hostColors.value.isNotEmpty) Cap.themeHostColors,
        Cap.packagesList,
        if (ksu.has('getPackagesInfo')) Cap.packagesInfo,
        Cap.shellExec,
        Cap.shellRoot,
        if (webuix) Cap.shellExecAsync,
        if (hasWorker) ...{Cap.opsCall, Cap.opsJobs},
        if (core != null) Cap.coreRust,
      },
      details: {
        'userAgent': ua,
        'moduleDir': moduleDir,
        'ksu': ksu.methods().join(', '),
        if (webui != null) 'webui': webui.methods().join(', '),
        if (module != null) module.name: module.methods().join(', '),
        'worker': hasWorker ? worker : 'missing ($worker)',
        'execBlockedMs': '${workerCheck.blocked?.inMilliseconds ?? '?'}',
      },
    ),
    config: config,
    window: window,
    navigation: navigation,
    lifecycle: lifecycle,
    storage: _RootStorage(shell, paths),
    files: _WebFiles(shell),
    feedback: _WebFeedback(ksu: ksu, module: module),
    theme: theme,
    packages: _WebPackages(ksu, shell),
    shell: shell,
    ops: hasWorker
        ? Ops(WorkerTransport(shell: shell, worker: worker, stateDir: '${paths.temp}/jobs'))
        : Ops.unavailable('The module has no ${config.workerName} in bin/'),
    core: core == null ? Core.unavailable('No core.wasm in this build') : Core(core),
  );
}

bool _hasNavigatorShare() =>
    web.window.navigator.getProperty<JSAny?>('share'.toJS)?.typeofEquals('function') ?? false;

/// Host events WebUI X posts to the page as JSON strings.
Stream<({String type, Map<String, Object?> data})> _wxEvents() {
  late StreamController<({String type, Map<String, Object?> data})> controller;
  void onMessage(web.Event event) {
    final data = (event as web.MessageEvent).data;
    Object? json = data.dartify();
    if (json is String) {
      try {
        json = jsonDecode(json);
      } on FormatException {
        return;
      }
    }
    if (json is! Map || json['type'] is! String) return;
    final type = json['type'] as String;
    if (!type.startsWith('WX_')) return;
    final payload = json['data'];
    controller.add((
      type: type,
      data: payload is Map ? payload.cast<String, Object?>() : const {},
    ));
  }

  final listener = onMessage.toJS;
  controller = StreamController.broadcast(
    onListen: () => web.window.addEventListener('message', listener),
    onCancel: () => web.window.removeEventListener('message', listener),
  );
  return controller.stream;
}

final _wx = _wxEvents();

class _WebWindow extends SurfaceWindow {
  _WebWindow({this.ksu, this.module});

  final HostObject? ksu;
  final HostObject? module;

  void start({required bool liveCss}) {
    if (!liveCss) return;
    _read();
    // The hosts set the variables on <html> and change them in place.
    web.MutationObserver(((JSArray<JSAny?> _, JSAny? _) => _read()).toJS)
        .observe(
          web.document.documentElement!,
          web.MutationObserverInit(attributes: true, attributeFilter: ['style'.toJS].toJS),
        );
    web.window.addEventListener('resize', ((web.Event _) => _read()).toJS);
    // A stylesheet may land after the first frame.
    var ticks = 0;
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      _read();
      if (++ticks >= 10) timer.cancel();
    });
    _wx.listen((event) {
      switch (event.type) {
        case 'WX_ON_INSETS':
          double value(String key) => (event.data[key] as num?)?.toDouble() ?? 0;
          // WebUI X sends physical pixels here; the CSS variables it injects
          // are in CSS pixels, so re-read those instead of trusting units.
          if (value('top') >= 0) _read();
        case 'WX_ON_KEYBOARD':
          final visible = event.data['visible'] == true;
          final height = (event.data['height'] as num?)?.toDouble() ?? 0;
          keyboardHeight.value = visible ? height / web.window.devicePixelRatio : 0;
      }
    });
  }

  static double _px(web.CSSStyleDeclaration style, List<String> names) {
    for (final name in names) {
      final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(style.getPropertyValue(name));
      if (match != null) return double.parse(match.group(0)!);
    }
    return 0;
  }

  void _read() {
    final style = web.window.getComputedStyle(web.document.documentElement!);
    double side(String side) => _px(style, ['--safe-area-inset-$side', '--window-inset-$side']);
    final insets = EdgeInsets.fromLTRB(side('left'), side('top'), side('right'), side('bottom'));
    if (insets != safeArea.value) safeArea.value = insets;
    final keyboard = _px(style, ['--window-keyboard-height']);
    if (keyboard > 0) keyboardHeight.value = keyboard;
  }

  @override
  Future<bool> setFullscreen(bool on) async {
    final ksu = this.ksu;
    if (ksu == null || !ksu.has('fullScreen')) return false;
    ksu.call('fullScreen', [on.toJS]);
    fullscreen.value = on;
    return true;
  }

  @override
  Future<bool> setLightStatusBars(bool light) async {
    final module = this.module;
    if (module == null || !module.has('setLightStatusBars')) return false;
    module.call('setLightStatusBars', [light.toJS]);
    return true;
  }
}

class _WebNavigation extends SurfaceNavigation {
  _WebNavigation({required this.ksu, required this.webui, required _WebWindow window}) {
    _wx.listen((event) {
      if (event.type == 'WX_ON_BACK') emitBack();
    });
  }

  final HostObject ksu;
  final HostObject? webui;

  @override
  Future<bool> exit() async {
    final webui = this.webui;
    if (webui != null && webui.has('exit')) {
      webui.call('exit');
      return true;
    }
    if (ksu.has('exit') && !ksu.has('mmrl')) {
      ksu.call('exit');
      return true;
    }
    return false;
  }
}

class _WebLifecycle extends SurfaceLifecycle {
  void start() {
    _wx.listen((event) {
      switch (event.type) {
        case 'WX_ON_PAUSE':
          emit(HostLifecycle.paused);
        case 'WX_ON_RESUME':
          emit(HostLifecycle.resumed);
      }
    });
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) => emit(
            web.document.visibilityState == 'hidden'
                ? HostLifecycle.paused
                : HostLifecycle.resumed,
          )).toJS,
    );
  }
}

class _KsuShell extends SurfaceShell {
  _KsuShell(this.ksu, {required this.async});

  final HostObject ksu;
  final bool async;

  @override
  Future<ExecResult> exec(
    String command, {
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 30),
  }) => ksuExec(ksu, command, cwd: cwd, env: env, timeout: timeout);
}

/// Writes [bytes] to [path] as root, in pieces a shell line can carry.
Future<ExecResult> _writeFile(SurfaceShell shell, String path, Uint8List bytes) async {
  const chunk = 48 * 1024;
  final temporary = '$path.surfaces-tmp';
  var result = await shell.exec(
    'mkdir -p ${shellQuote(_parent(path))} && : > ${shellQuote(temporary)}',
  );
  if (!result.ok) return result;
  for (var offset = 0; offset < bytes.length; offset += chunk) {
    final end = offset + chunk < bytes.length ? offset + chunk : bytes.length;
    final encoded = base64.encode(bytes.sublist(offset, end));
    result = await shell.exec(
      "printf '%s' ${shellQuote(encoded)} | base64 -d >> ${shellQuote(temporary)}",
    );
    if (!result.ok) return result;
  }
  return shell.exec('mv -f ${shellQuote(temporary)} ${shellQuote(path)}');
}

String _parent(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

class _RootStorage extends SurfaceStorage {
  _RootStorage(this.shell, this._paths);

  final SurfaceShell shell;
  final StoragePaths _paths;

  @override
  StoragePaths get paths => _paths;

  String _path(String name) {
    SurfaceStorage.checkName(name);
    return '${_paths.appData}/$name';
  }

  @override
  Future<String?> readText(String name) async {
    final path = shellQuote(_path(name));
    final result = await shell.exec('[ -f $path ] || exit 3; base64 $path');
    if (result.code == 3) return null;
    if (!result.ok) throw StateError('Could not read $name: ${result.stderr}');
    return utf8.decode(base64.decode(result.stdout.replaceAll(RegExp(r'\s'), '')));
  }

  @override
  Future<void> writeText(String name, String text) async {
    final result = await _writeFile(shell, _path(name), utf8.encode(text));
    if (!result.ok) throw StateError('Could not write $name: ${result.stderr}');
  }

  @override
  Future<void> delete(String name) async {
    await shell.exec('rm -f ${shellQuote(_path(name))}');
  }
}

class _LocalStorage extends SurfaceStorage {
  _LocalStorage(this.appId);

  final String appId;

  String _key(String name) {
    SurfaceStorage.checkName(name);
    return 'surfaces:$appId:$name';
  }

  @override
  Future<String?> readText(String name) async =>
      web.window.localStorage.getItem(_key(name));

  @override
  Future<void> writeText(String name, String text) async =>
      web.window.localStorage.setItem(_key(name), text);

  @override
  Future<void> delete(String name) async =>
      web.window.localStorage.removeItem(_key(name));
}

class _WebFiles extends SurfaceFiles {
  _WebFiles(this.rootShell);

  /// On WebUI hosts saving goes through the root shell into Downloads; a
  /// plain browser downloads.
  final SurfaceShell? rootShell;

  @override
  Future<PickedFile?> pick({List<String> accept = const []}) async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept.join(',');
    input.style.display = 'none';
    web.document.body!.append(input);
    final completer = Completer<web.File?>();
    input.addEventListener(
      'change',
      ((web.Event _) {
        final files = input.files;
        if (!completer.isCompleted) {
          completer.complete(files != null && files.length > 0 ? files.item(0) : null);
        }
      }).toJS,
    );
    input.addEventListener('cancel', ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS);
    input.click();
    final file = await completer.future;
    input.remove();
    if (file == null) return null;
    final buffer = await file.arrayBuffer().toDart;
    return PickedFile(
      name: file.name,
      bytes: buffer.toDart.asUint8List(),
      mimeType: file.type.isEmpty ? null : file.type,
    );
  }

  @override
  Future<String?> save(String name, Uint8List bytes) async {
    final safe = name.replaceAll(RegExp(r'[/\\]'), '_');
    final shell = rootShell;
    if (shell != null) {
      final path = '/sdcard/Download/$safe';
      final result = await _writeFile(shell, path, bytes);
      return result.ok ? path : null;
    }
    final blob = web.Blob([bytes.toJS].toJS);
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = safe;
    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    Timer(const Duration(seconds: 5), () => web.URL.revokeObjectURL(url));
    return 'download';
  }
}

class _WebFeedback extends SurfaceFeedback {
  _WebFeedback({required this.ksu, required this.module});

  final HostObject? ksu;
  final HostObject? module;

  @override
  Future<void> toast(String message) async {
    final ksu = this.ksu;
    if (ksu != null && ksu.has('toast')) {
      ksu.call('toast', [message.toJS]);
    } else {
      await super.toast(message);
    }
  }

  @override
  Future<bool> share(String text) async {
    final module = this.module;
    if (module != null && module.has('shareText')) {
      module.call('shareText', [text.toJS]);
      return true;
    }
    if (_hasNavigatorShare()) {
      try {
        await web.window.navigator.share(web.ShareData(text: text)).toDart;
        return true;
      } catch (_) {
        // Cancelled or refused; fall back to copying.
      }
    }
    return super.share(text);
  }
}

class _WebTheme extends SurfaceTheme {
  _WebTheme(this.module) {
    _read();
  }

  final HostObject? module;

  static const _names = [
    'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer',
    'secondary', 'onSecondary', 'secondaryContainer', 'onSecondaryContainer',
    'tertiary', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer',
    'error', 'onError', 'background', 'onBackground', 'surface', 'onSurface',
    'surfaceVariant', 'onSurfaceVariant', 'surfaceContainer',
    'surfaceContainerHigh', 'surfaceContainerHighest', 'surfaceContainerLow',
    'outline', 'outlineVariant', 'inverseSurface', 'inverseOnSurface',
  ];

  static Color? _parse(String text) {
    final value = text.trim();
    final hex = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').firstMatch(value);
    if (hex != null) {
      final digits = hex.group(1)!;
      final argb = digits.length == 6 ? 'ff$digits' : digits.substring(6) + digits.substring(0, 6);
      return Color(int.parse(argb, radix: 16));
    }
    final rgb = RegExp(r'^rgba?\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)(?:[,\s/]+([\d.]+))?\s*\)$')
        .firstMatch(value);
    if (rgb != null) {
      final alpha = rgb.group(4) == null ? 1.0 : double.parse(rgb.group(4)!);
      return Color.fromRGBO(
        int.parse(rgb.group(1)!),
        int.parse(rgb.group(2)!),
        int.parse(rgb.group(3)!),
        alpha,
      );
    }
    return null;
  }

  void _read() {
    final style = web.window.getComputedStyle(web.document.documentElement!);
    final colors = <String, Color>{};
    for (final name in _names) {
      final color = _parse(style.getPropertyValue('--$name'));
      if (color != null) colors[name] = color;
    }
    hostColors.value = colors;
  }

  @override
  bool? get darkMode {
    final module = this.module;
    if (module == null || !module.has('isDarkMode')) return null;
    return module.callBool('isDarkMode');
  }
}

class _WebPackages extends SurfacePackages {
  _WebPackages(this.ksu, this.shell);

  final HostObject ksu;
  final SurfaceShell shell;

  @override
  Future<List<AppPackage>> list({bool system = false}) async {
    List<String> names;
    if (ksu.has('listPackages')) {
      final json = parseJson(ksu.callString('listPackages', [(system ? 'system' : 'user').toJS]));
      names = json is List ? json.whereType<String>().toList() : const [];
    } else {
      final result = await shell.exec('pm list packages ${system ? '-s' : '-3'}');
      names = [
        for (final line in result.stdout.split('\n'))
          if (line.startsWith('package:')) line.substring(8).trim(),
      ];
    }
    names.sort();
    if (!ksu.has('getPackagesInfo') || names.isEmpty) {
      return [for (final name in names) AppPackage(packageName: name, system: system)];
    }
    final info = parseJson(ksu.callString('getPackagesInfo', [jsonEncode(names).toJS]));
    if (info is! List) {
      return [for (final name in names) AppPackage(packageName: name, system: system)];
    }
    final apps = [
      for (final item in info.whereType<Map>())
        AppPackage(
          packageName: '${item['packageName']}',
          label: item['appLabel'] as String?,
          versionName: item['versionName'] as String?,
          system: item['isSystem'] == true,
        ),
    ];
    apps.sort((a, b) => (a.label ?? a.packageName).toLowerCase()
        .compareTo((b.label ?? b.packageName).toLowerCase()));
    return apps;
  }
}
