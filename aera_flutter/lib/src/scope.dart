import 'package:flutter/widgets.dart';

import 'system.dart';

/// Routes AERA's back gesture to the app's navigator, the way Flutter does
/// for Android's back button.
///
/// Place it in `MaterialApp.builder` (or `WidgetsApp.builder`), so it sits
/// above the navigator:
///
/// ```dart
/// MaterialApp(builder: (context, child) => AeraScope(child: child!))
/// ```
///
/// It listens for the [NavigationNotification]s every [Navigator] and
/// [PopScope] sends (on Android they drive predictive back) and tells AERA
/// whether the app can handle Back. When it can, Back pops the top route;
/// when it cannot, Back leaves the app for AERA's previous screen.
///
/// It also adds AERA's safe area ([AeraSystem.padding], the rounded corners
/// and the swipe-up strip at the bottom of the screen) to the app's
/// [MediaQuery] padding, and AERA's gesture areas to its
/// `systemGestureInsets`, so [SafeArea] and Material widgets keep clear of
/// them.
class AeraScope extends StatefulWidget {
  const AeraScope({super.key, required this.child});

  final Widget child;

  @override
  State<AeraScope> createState() => _AeraScopeState();
}

class _AeraScopeState extends State<AeraScope> {
  bool? _reported;

  @override
  void initState() {
    super.initState();
    AeraSystem.instance.refreshState();
  }

  bool _onNavigation(NavigationNotification notification) {
    if (_reported != notification.canHandlePop) {
      _reported = notification.canHandlePop;
      AeraSystem.instance.setNavigationState(
        canGoBack: notification.canHandlePop,
      );
    }
    // Let WidgetsApp see it too.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final system = AeraSystem.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([system.padding, system.gestureInsets]),
      builder: (context, child) => MediaQuery(
        data: _withAera(
          MediaQuery.of(context),
          system.padding.value,
          system.gestureInsets.value,
        ),
        child: child!,
      ),
      child: NotificationListener<NavigationNotification>(
        onNotification: _onNavigation,
        child: widget.child,
      ),
    );
  }
}

EdgeInsets _max(EdgeInsets a, EdgeInsets b) => EdgeInsets.fromLTRB(
  a.left > b.left ? a.left : b.left,
  a.top > b.top ? a.top : b.top,
  a.right > b.right ? a.right : b.right,
  a.bottom > b.bottom ? a.bottom : b.bottom,
);

/// [data] with AERA's [padding] and [gestures] (physical pixels) added the
/// way the engine adds Android's: padding shrinks under the keyboard's view
/// inset, view padding does not.
MediaQueryData _withAera(
  MediaQueryData data,
  EdgeInsets padding,
  EdgeInsets gestures,
) {
  final ratio = data.devicePixelRatio;
  final viewPadding = _max(data.viewPadding, padding / ratio);
  return data.copyWith(
    viewPadding: viewPadding,
    padding:
        (viewPadding - data.viewInsets).clamp(
              EdgeInsets.zero,
              EdgeInsetsGeometry.infinity,
            )
            as EdgeInsets,
    systemGestureInsets: _max(data.systemGestureInsets, gestures / ratio),
  );
}
