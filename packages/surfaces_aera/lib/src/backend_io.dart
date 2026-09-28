import 'dart:io';
import 'dart:ui' as ui;

import 'package:aera_flutter/aera_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:surfaces/surfaces.dart';
import 'package:surfaces/surfaces_io.dart';

/// Recognises AERA Recovery's app slot and its PC simulator.
///
/// Inside AERA: Back is AERA's edge gesture and top-bar arrow (through
/// `AeraScope`), the safe area keeps clear of the rounded corners and the
/// swipe-up strip, storage is the jail's `/profile`, saved files go to
/// `/downloads` (the phone's `/sdcard/AERA/Downloads`), and ops and the Rust
/// core run in-process through the app's flutter_rust_bridge library.
class AeraBackend extends SurfaceBackend {
  const AeraBackend();

  static bool get detected =>
      Platform.isLinux &&
      (Platform.environment.containsKey('AERA_FLUTTER_ROOT') ||
          File('/usr/bin/aera-browser-worker').existsSync());

  @override
  Future<Surface?> tryCreate(SurfaceConfig config) async {
    if (!detected) return null;
    final jail = Directory('/profile').existsSync();
    final paths = jail
        ? const StoragePaths(appData: '/profile', downloads: '/downloads', temp: '/tmp')
        : desktopPaths('aera-flutter/${config.appId}');
    final hasShell = File('/bin/sh').existsSync();
    final ops = config.nativeOps;
    final core = config.nativeCore;
    const renderer = String.fromEnvironment('AERA_RENDERER', defaultValue: 'gl');
    const build = String.fromEnvironment('AERA_APP_BUILD');
    final window = _AeraWindow()..start();
    return _AeraSurface(
      info: HostInfo(
        kind: HostKind.aera,
        name: jail ? 'AERA Recovery' : 'AERA simulator',
        tier: 'aera',
        engine: 'AERA embedder ($renderer)',
        capabilities: {
          Cap.backIntercept,
          Cap.insets,
          Cap.insetsLive,
          Cap.keyboardInset,
          Cap.storagePersistent,
          Cap.filesSave,
          if (hasShell) ...{Cap.shellExec, Cap.shellExecAsync},
          if (ops != null) Cap.opsCall,
          if (ops != null && ops.supportsJobs) Cap.opsJobs,
          if (core != null) Cap.coreRust,
        },
        details: {
          'appData': paths.appData,
          'downloads': paths.downloads,
          'renderer': renderer,
          if (build.isNotEmpty) 'build': build,
          'kernel': Platform.operatingSystemVersion,
        },
      ),
      config: config,
      window: window,
      storage: IoStorage(paths),
      files: IoFiles(paths),
      shell: hasShell ? IoShell() : null,
      ops: ops == null ? Ops.unavailable('The app passed no nativeOps') : Ops(ops),
      core: core == null ? Core.unavailable('The app passed no nativeCore') : Core(core),
    );
  }
}

class _AeraSurface extends Surface {
  _AeraSurface({
    required super.info,
    required super.config,
    super.window,
    super.storage,
    super.files,
    super.shell,
    super.ops,
    super.core,
  });

  // AeraScope tells AERA whether Back has somewhere to go, routes the
  // gesture to the navigator, and adds AERA's safe area to MediaQuery.
  @override
  Widget wrap(Widget child) => AeraScope(child: child);
}

class _AeraWindow extends SurfaceWindow {
  void start() {
    final system = AeraSystem.instance;
    void update() {
      final views = ui.PlatformDispatcher.instance.views;
      final ratio = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
      safeArea.value = system.padding.value / ratio;
    }

    system.padding.addListener(update);
    system.keyboardVisible.addListener(() {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isEmpty) return;
      final view = views.first;
      keyboardHeight.value = system.keyboardVisible.value
          ? view.viewInsets.bottom / view.devicePixelRatio
          : 0;
    });
    update();
  }
}
