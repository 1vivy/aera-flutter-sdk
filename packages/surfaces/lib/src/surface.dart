import 'package:flutter/widgets.dart';

import 'core.dart';
import 'fallback.dart';
import 'host.dart';
import 'ops.dart';
import 'services.dart';

/// What the app tells surfaces about itself.
class SurfaceConfig {
  const SurfaceConfig({
    required this.appId,
    this.appName = '',
    this.workerName = 'worker',
    this.coreWasm = 'core.wasm',
    this.nativeCore,
    this.nativeOps,
  });

  /// The module id on WebUI hosts (`/data/adb/modules/<appId>`), and the
  /// app data folder's name elsewhere. Letters, digits, `.`, `_`, `-`.
  final String appId;

  /// Shown in host reports; defaults to [appId].
  final String appName;

  /// The ops worker's file name in the module's `bin/` folder on WebUI.
  final String workerName;

  /// Where the Rust core's wasm build sits in the web build, relative to the
  /// page.
  final String coreWasm;

  /// The Rust core on native targets, usually the app's flutter_rust_bridge
  /// `core_call` and `core_bytes`.
  final CoreBinding? nativeCore;

  /// Ops on native targets, usually the app's flutter_rust_bridge
  /// `ops_call`, `ops_start`, `ops_poll` and `ops_cancel`.
  final OpsTransport? nativeOps;

  String get displayName => appName.isEmpty ? appId : appName;
}

/// A host platform implementation. `package:surfaces_webui` and
/// `package:surfaces_aera` each provide one; the app lists the ones it
/// targets in [Surface.init], which is how a template picks its platforms.
abstract class SurfaceBackend {
  const SurfaceBackend();

  /// A surface for this host, or null when the app is not running on it.
  Future<Surface?> tryCreate(SurfaceConfig config);
}

/// The host the app runs in, detected once by [Surface.init].
class Surface {
  Surface({
    required this.info,
    required this.config,
    SurfaceWindow? window,
    SurfaceNavigation? navigation,
    SurfaceLifecycle? lifecycle,
    SurfaceStorage? storage,
    SurfaceFiles? files,
    SurfaceFeedback? feedback,
    SurfaceTheme? theme,
    SurfacePackages? packages,
    SurfaceShell? shell,
    Ops? ops,
    Core? core,
  }) : window = window ?? SurfaceWindow(),
       navigation = navigation ?? SurfaceNavigation(),
       lifecycle = lifecycle ?? SurfaceLifecycle(),
       storage = storage ?? SurfaceStorage(),
       files = files ?? SurfaceFiles(),
       feedback = feedback ?? SurfaceFeedback(),
       theme = theme ?? SurfaceTheme(),
       packages = packages ?? SurfacePackages(),
       shell = shell ?? SurfaceShell(),
       ops = ops ?? Ops.unavailable(),
       core = core ?? Core.unavailable();

  final HostInfo info;
  final SurfaceConfig config;
  final SurfaceWindow window;
  final SurfaceNavigation navigation;
  final SurfaceLifecycle lifecycle;
  final SurfaceStorage storage;
  final SurfaceFiles files;
  final SurfaceFeedback feedback;
  final SurfaceTheme theme;
  final SurfacePackages packages;
  final SurfaceShell shell;
  final Ops ops;
  final Core core;

  /// Wraps the app for this host's own widgets (AERA's back gesture scope,
  /// for instance). [SurfaceScope] calls it.
  Widget wrap(Widget child) => child;

  static Surface? _instance;

  /// The surface [init] found.
  static Surface get instance =>
      _instance ??
      (throw StateError('Call `await Surface.init(...)` in main() first'));

  static bool get isInitialized => _instance != null;

  /// Detects the host: the first of [backends] that recognises it wins;
  /// with none, a [FallbackSurface] for desktop, tests or an unknown host.
  static Future<Surface> init(
    SurfaceConfig config, {
    List<SurfaceBackend> backends = const [],
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    for (final backend in backends) {
      final surface = await backend.tryCreate(config);
      if (surface != null) return _instance = surface;
    }
    return _instance = await FallbackSurface.create(config);
  }

  /// Replaces the instance, for tests.
  @visibleForTesting
  static set debugInstance(Surface? surface) => _instance = surface;
}
