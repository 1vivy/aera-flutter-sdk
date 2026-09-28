/// One API for what the host shell gives a Flutter app.
///
/// A surfaces app runs unchanged as a KernelSU / WebUI X module, a plain web
/// page, an AERA Recovery app and a desktop app. It never asks which of those
/// it is on; it asks for capabilities, and every call has a documented
/// fallback when the host lacks the feature.
///
/// ```dart
/// Future<void> main() async {
///   await Surface.init(
///     const SurfaceConfig(appId: 'my_app'),
///     backends: const [WebUiBackend(), AeraBackend()],
///   );
///   runApp(MaterialApp(
///     builder: (context, child) => SurfaceScope(child: child!),
///     home: const Home(),
///   ));
/// }
/// ```
///
/// [SurfaceScope] wires the host's back button, insets, lifecycle and toasts
/// into Flutter; everything else is on [Surface.instance].
library;

export 'src/capability.dart';
export 'src/core.dart';
export 'src/host.dart';
export 'src/ops.dart';
export 'src/scope.dart';
export 'src/services.dart';
export 'src/shell.dart';
export 'src/surface.dart';
export 'src/worker.dart';
export 'src/fallback.dart' show FallbackSurface;
