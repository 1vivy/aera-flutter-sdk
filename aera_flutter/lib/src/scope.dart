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
class AeraScope extends StatefulWidget {
  const AeraScope({super.key, required this.child});

  final Widget child;

  @override
  State<AeraScope> createState() => _AeraScopeState();
}

class _AeraScopeState extends State<AeraScope> {
  bool? _reported;

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
    return NotificationListener<NavigationNotification>(
      onNotification: _onNavigation,
      child: widget.child,
    );
  }
}
