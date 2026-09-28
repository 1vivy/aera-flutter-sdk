import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// AERA's look: accent colour, light or dark, interface size and clock.
///
/// Light/dark, the interface size (as the text scale) and the 24-hour clock
/// already reach Flutter through [MediaQuery], as on Android; the accent
/// colour is AERA's own, for seeding a [ColorScheme].
class AeraTheme {
  const AeraTheme({
    required this.accent,
    required this.light,
    required this.interfaceSize,
    required this.clock24,
  });

  final Color accent;
  final bool light;

  /// `small`, `normal` or `large`.
  final String interfaceSize;
  final bool clock24;

  Brightness get brightness => light ? Brightness.light : Brightness.dark;
}

/// Recovery facts: AERA's version and channel, the phone and its active slot.
class RecoveryInfo {
  const RecoveryInfo({
    required this.version,
    required this.channel,
    required this.status,
    required this.device,
    required this.slot,
  });

  final String version;
  final String channel;
  final String status;
  final String device;

  /// `A` or `B`, empty on phones without slots.
  final String slot;
}

class BatteryState {
  const BatteryState({
    this.level,
    this.status,
    this.health,
    this.temperatureC,
    this.voltageMv,
    this.currentMa,
  });

  /// Percent.
  final int? level;

  /// The kernel's words: `Charging`, `Discharging`, `Full`, ...
  final String? status;
  final String? health;
  final double? temperatureC;
  final int? voltageMv;
  final int? currentMa;
}

class WifiState {
  const WifiState({required this.connected, this.ssid, this.ipAddress});

  final bool connected;
  final String? ssid;
  final String? ipAddress;
}

enum RebootTarget { system, recovery, bootloader, fastboot, poweroff }

/// Recovery itself, for apps on AERA's generic plugin host, where plugins
/// are recovery modules running as root.
///
/// Every call throws [PlatformException] when the phone lacks the part (no
/// flashlight, say) and [MissingPluginException] outside AERA's generic host
/// (on a PC, or in the browser slot).
///
/// `HapticFeedback` and `Clipboard` from `package:flutter/services.dart`
/// work too: haptics use the phone's vibrator with AERA's haptic settings,
/// and the clipboard is shared by every Flutter app until recovery restarts.
class AeraRecovery {
  AeraRecovery._();

  static const MethodChannel channel = MethodChannel(
    'aera/recovery',
    JSONMethodCodec(),
  );

  static Future<Map<String, Object?>> _map(String method) async =>
      (await channel.invokeMapMethod<String, Object?>(method))!;

  static Future<AeraTheme> theme() async {
    final m = await _map('getTheme');
    return AeraTheme(
      accent: Color(0xff000000 | (m['accent'] as int)),
      light: m['light'] as bool,
      interfaceSize: m['interfaceSize'] as String,
      clock24: m['clock24'] as bool,
    );
  }

  static Future<RecoveryInfo> info() async {
    final m = await _map('getInfo');
    return RecoveryInfo(
      version: m['version'] as String,
      channel: m['channel'] as String,
      status: m['status'] as String,
      device: m['device'] as String,
      slot: m['slot'] as String,
    );
  }

  static Future<BatteryState> battery() async {
    final m = await _map('getBattery');
    return BatteryState(
      level: m['level'] as int?,
      status: m['status'] as String?,
      health: m['health'] as String?,
      temperatureC: (m['temperatureC'] as num?)?.toDouble(),
      voltageMv: m['voltageMv'] as int?,
      currentMa: m['currentMa'] as int?,
    );
  }

  static Future<WifiState> wifi() async {
    final m = await _map('getWifi');
    return WifiState(
      connected: m['connected'] as bool,
      ssid: m['ssid'] as String?,
      ipAddress: m['ipAddress'] as String?,
    );
  }

  /// Screen brightness in percent.
  static Future<int> brightness() async =>
      (await channel.invokeMethod<int>('getBrightness'))!;

  /// Sets the backlight (10 to 100 percent) while the app runs. AERA's own
  /// brightness setting is not changed.
  static Future<void> setBrightness(int percent) =>
      channel.invokeMethod<void>('setBrightness', percent);

  static Future<bool> hasFlashlight() async =>
      (await channel.invokeMethod<bool>('hasFlashlight'))!;

  static Future<void> setFlashlight(bool on) =>
      channel.invokeMethod<void>('setFlashlight', on);

  /// Runs the vibrator for [duration], ignoring AERA's haptic settings. For
  /// feedback on touches use `HapticFeedback`, which follows them.
  static Future<void> vibrate([
    Duration duration = const Duration(milliseconds: 30),
  ]) => channel.invokeMethod<void>('vibrate', duration.inMilliseconds);

  /// Restarts the phone into [target] at once, as recovery's reboot menu
  /// does. Ask the user first.
  static Future<void> reboot(RebootTarget target) =>
      channel.invokeMethod<void>('reboot', target.name);
}
