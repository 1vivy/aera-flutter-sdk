import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'capability.dart';
import 'surface.dart';

/// Wires the host into Flutter: Back, safe area and toasts.
///
/// Put it in `MaterialApp.builder` (or `WidgetsApp.builder`), above the
/// navigator:
///
/// ```dart
/// MaterialApp(builder: (context, child) => SurfaceScope(child: child!))
/// ```
///
/// - **Back.** Host Back pops routes and respects [PopScope], on every
///   host: WebUI X's `WX_ON_BACK`, the KernelSU family's page history,
///   AERA's edge gesture. On the first page it closes the app where the host
///   allows ([Cap.exit]).
/// - **Safe area.** The host's insets go into [MediaQueryData.padding], so
///   [SafeArea], [Scaffold] and [NavigationBar] keep clear of bars and
///   cutouts. Flutter on the web never sees them otherwise.
/// - **Toasts.** On hosts without their own toasts,
///   `Surface.instance.feedback.toast()` shows one here.
class SurfaceScope extends StatefulWidget {
  const SurfaceScope({super.key, required this.child, this.surface});

  final Widget child;

  /// Defaults to [Surface.instance].
  final Surface? surface;

  @override
  State<SurfaceScope> createState() => _SurfaceScopeState();
}

class _SurfaceScopeState extends State<SurfaceScope>
    with WidgetsBindingObserver {
  late Surface _surface;
  StreamSubscription<void>? _back;
  StreamSubscription<String>? _toasts;
  bool? _canPop;
  String? _toast;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _surface = widget.surface ?? Surface.instance;
    // Registered after WidgetsApp's own observer, so this only hears Back
    // the navigator did not want: the first page.
    WidgetsBinding.instance.addObserver(this);
    _back = _surface.navigation.onBack.listen((_) => simulateBack());
    _toasts = _surface.feedback.inAppToasts.listen(_showToast);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _back?.cancel();
    _toasts?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    if (_surface.info.has(Cap.exit)) {
      return _surface.navigation.exit();
    }
    // Let Flutter do what it does on this platform (on the web: leave the
    // page's history, so the host's next Back closes the WebUI).
    return false;
  }

  bool _onNavigation(NavigationNotification notification) {
    if (_canPop != notification.canHandlePop) {
      _canPop = notification.canHandlePop;
      _surface.navigation.setCanPop(notification.canHandlePop);
    }
    return false;
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final window = _surface.window;
    Widget child = NotificationListener<NavigationNotification>(
      onNotification: _onNavigation,
      child: widget.child,
    );
    child = ValueListenableBuilder(
      valueListenable: window.safeArea,
      builder: (context, safeArea, child) => MediaQuery(
        data: withSafeArea(MediaQuery.of(context), safeArea),
        child: child!,
      ),
      child: child,
    );
    child = Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(child: child),
        _ToastLayer(message: _toast),
      ],
    );
    return _surface.wrap(child);
  }
}

/// Delivers a Back press exactly as the engine would (a `popRoute` on the
/// navigation channel), so the navigator, [PopScope] and every
/// [WidgetsBindingObserver] see it the usual way.
void simulateBack() {
  final data = SystemChannels.navigation.codec.encodeMethodCall(
    const MethodCall('popRoute'),
  );
  ServicesBinding.instance.channelBuffers.push(
    SystemChannels.navigation.name,
    data,
    (_) {},
  );
}

EdgeInsets _max(EdgeInsets a, EdgeInsets b) => EdgeInsets.fromLTRB(
  a.left > b.left ? a.left : b.left,
  a.top > b.top ? a.top : b.top,
  a.right > b.right ? a.right : b.right,
  a.bottom > b.bottom ? a.bottom : b.bottom,
);

/// [data] with the host's [safeArea] (logical pixels) added the way the
/// engine adds Android's system bars: view padding keeps it, padding
/// shrinks under the keyboard.
@visibleForTesting
MediaQueryData withSafeArea(MediaQueryData data, EdgeInsets safeArea) {
  if (safeArea == EdgeInsets.zero) return data;
  final viewPadding = _max(data.viewPadding, safeArea);
  return data.copyWith(
    viewPadding: viewPadding,
    padding: (viewPadding - data.viewInsets).clamp(
      EdgeInsets.zero,
      EdgeInsetsGeometry.infinity,
    ) as EdgeInsets,
  );
}

class _ToastLayer extends StatelessWidget {
  const _ToastLayer({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    return Positioned(
      left: 24,
      right: 24,
      bottom: media.padding.bottom + media.viewInsets.bottom + 88,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: message == null ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: Center(
            child: Material(
              color: theme.colorScheme.inverseSurface,
              elevation: 4,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Text(
                  message ?? '',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
