/// Spacing and shape shared by every surfaces app, so pages built by
/// different apps line up.
abstract final class Gap {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;
}

abstract final class Radii {
  static const double card = 16;
  static const double chip = 8;
  static const double pill = 999;
}

/// The width content stops growing at on wide screens (desktop, a browser
/// tab), so a phone layout stays readable.
const double contentMaxWidth = 720;
