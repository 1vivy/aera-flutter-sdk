import 'package:flutter/material.dart';
import 'package:surfaces/surfaces.dart';

import 'theme.dart';

/// A [MaterialApp] for surfaces apps: [SurfaceScope] in place, and a light
/// and dark theme that follow the host's colours.
class SurfacesApp extends StatelessWidget {
  const SurfacesApp({
    super.key,
    required this.title,
    required this.home,
    this.seed = Colors.teal,
    this.themeMode,
    this.navigatorKey,
  });

  final String title;
  final Widget home;
  final Color seed;

  /// Defaults to the host's dark mode where it says, else the system's.
  final ThemeMode? themeMode;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    final surface = Surface.instance;
    return ValueListenableBuilder(
      valueListenable: surface.theme.hostColors,
      builder: (context, hostColors, _) {
        final dark = surface.theme.darkMode;
        return MaterialApp(
          title: title,
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: surfacesTheme(seed: seed, brightness: Brightness.light, hostColors: hostColors),
          darkTheme: surfacesTheme(seed: seed, brightness: Brightness.dark, hostColors: hostColors),
          themeMode: themeMode ??
              switch (dark) {
                true => ThemeMode.dark,
                false => ThemeMode.light,
                null => ThemeMode.system,
              },
          builder: (context, child) => SurfaceScope(child: child!),
          home: home,
        );
      },
    );
  }
}
