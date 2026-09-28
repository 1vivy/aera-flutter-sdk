import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the app's theme.
///
/// With host colours (WebUI hosts with Material You on publish
/// `/internal/colors.css`) the scheme is seeded from the host's primary and
/// takes every role the host names, so the module looks like its manager.
/// Without, it is seeded from [seed].
ThemeData surfacesTheme({
  required Color seed,
  required Brightness brightness,
  Map<String, Color> hostColors = const {},
}) {
  var scheme = ColorScheme.fromSeed(
    seedColor: hostColors['primary'] ?? seed,
    brightness: brightness,
  );
  // Host roles only when the host's scheme matches our brightness; a light
  // manager's surface on a dark app would be unreadable.
  final hostSurface = hostColors['surface'] ?? hostColors['background'];
  final hostIsDark = hostSurface == null
      ? null
      : ThemeData.estimateBrightnessForColor(hostSurface) == Brightness.dark;
  if (hostIsDark == (brightness == Brightness.dark)) {
    Color pick(String name, Color fallback) => hostColors[name] ?? fallback;
    scheme = scheme.copyWith(
      primary: pick('primary', scheme.primary),
      onPrimary: pick('onPrimary', scheme.onPrimary),
      primaryContainer: pick('primaryContainer', scheme.primaryContainer),
      onPrimaryContainer: pick('onPrimaryContainer', scheme.onPrimaryContainer),
      secondary: pick('secondary', scheme.secondary),
      onSecondary: pick('onSecondary', scheme.onSecondary),
      secondaryContainer: pick('secondaryContainer', scheme.secondaryContainer),
      onSecondaryContainer: pick('onSecondaryContainer', scheme.onSecondaryContainer),
      tertiary: pick('tertiary', scheme.tertiary),
      error: pick('error', scheme.error),
      surface: pick('surface', pick('background', scheme.surface)),
      onSurface: pick('onSurface', pick('onBackground', scheme.onSurface)),
      onSurfaceVariant: pick('onSurfaceVariant', scheme.onSurfaceVariant),
      surfaceContainer: pick('surfaceContainer', scheme.surfaceContainer),
      surfaceContainerHigh: pick('surfaceContainerHigh', scheme.surfaceContainerHigh),
      surfaceContainerHighest: pick('surfaceContainerHighest', scheme.surfaceContainerHighest),
      surfaceContainerLow: pick('surfaceContainerLow', scheme.surfaceContainerLow),
      outline: pick('outline', scheme.outline),
      outlineVariant: pick('outlineVariant', scheme.outlineVariant),
    );
  }
  return ThemeData(
    colorScheme: scheme,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainer,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: Gap.m),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.chip)),
    ),
    // WebUI hosts draw no page transition of their own; keep Android's.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
