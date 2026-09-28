import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'shell.dart';

// Every service here works on every host. The base classes are the
// fallbacks; a backend subclasses only what its host really offers.

/// The window the app draws in: safe area, keyboard, full screen, bars.
class SurfaceWindow {
  /// The part of the window the host's bars, cutouts or rounded corners
  /// cover, in logical pixels. [SurfaceScope] adds it to
  /// [MediaQueryData.padding], so [SafeArea] and [Scaffold] keep clear of it.
  final ValueNotifier<EdgeInsets> safeArea = ValueNotifier(EdgeInsets.zero);

  /// The on-screen keyboard's height in logical pixels, when the host tells.
  /// Flutter's own `viewInsets` stay the source of truth for layout.
  final ValueNotifier<double> keyboardHeight = ValueNotifier(0);

  /// Whether the app asked for full screen and the host did it.
  final ValueNotifier<bool> fullscreen = ValueNotifier(false);

  /// Hides or shows the host's bars. Returns false when the host cannot.
  Future<bool> setFullscreen(bool on) async => false;

  /// Asks for dark status bar icons (for a light app bar) or light ones.
  /// Returns false when the host cannot.
  Future<bool> setLightStatusBars(bool light) async => false;
}

/// The host's Back and the app's way out.
class SurfaceNavigation {
  final _back = StreamController<void>.broadcast();

  /// Back presses the host sends to the app itself, rather than through
  /// Flutter's own route popping (WebUI X's `WX_ON_BACK`). [SurfaceScope]
  /// turns each into a route pop that respects [PopScope].
  Stream<void> get onBack => _back.stream;

  /// For backends: delivers a Back press.
  @protected
  void emitBack() => _back.add(null);

  /// Tells the host whether the app has somewhere to go back to.
  /// [SurfaceScope] keeps this in step with the navigator.
  void setCanPop(bool canPop) {}

  /// Closes the app. Returns false when the host has no way to; the app
  /// then stays on its first page.
  Future<bool> exit() async => false;
}

/// Host lifecycle events, beyond Flutter's own [AppLifecycleState].
enum HostLifecycle { resumed, paused }

class SurfaceLifecycle {
  final _events = StreamController<HostLifecycle>.broadcast();

  /// Pause and resume as the host reports them. Empty on hosts that do not.
  Stream<HostLifecycle> get events => _events.stream;

  @protected
  void emit(HostLifecycle event) => _events.add(event);
}

/// Where the app keeps its files on this host.
class StoragePaths {
  const StoragePaths({this.appData = '', this.downloads = '', this.temp = ''});

  /// Private, survives restarts. Empty when the host has no file system the
  /// app can name (a plain browser).
  final String appData;

  /// Where the user finds saved files.
  final String downloads;

  /// Scratch space.
  final String temp;
}

/// Small text documents the app keeps, by name.
///
/// WebUI keeps them in root-owned files under `/data/adb/<appId>`, a plain
/// browser in `localStorage`, AERA and desktop in the app data folder. The
/// fallback keeps them in memory only.
class SurfaceStorage {
  final _memory = <String, String>{};

  StoragePaths get paths => const StoragePaths();

  Future<String?> readText(String name) async => _memory[name];

  Future<void> writeText(String name, String text) async =>
      _memory[name] = text;

  Future<void> delete(String name) async => _memory.remove(name);

  /// Names must be plain file names.
  @protected
  static void checkName(String name) {
    if (name.isEmpty ||
        name.length > 100 ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) ||
        name.startsWith('.')) {
      throw ArgumentError.value(name, 'name', 'Use letters, digits, . _ -');
    }
  }
}

/// A file the user picked.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.bytes,
    this.path,
    this.mimeType,
  });

  final String name;
  final Uint8List bytes;

  /// Where it is, when the host gives a path (not on the web).
  final String? path;
  final String? mimeType;

  int get size => bytes.length;
}

class SurfaceFiles {
  /// Lets the user pick one file. Null when they cancel or the host has no
  /// picker ([Cap.filesPick]).
  Future<PickedFile?> pick({List<String> accept = const []}) async => null;

  /// Saves [bytes] where the user finds files, as [name]. Returns where it
  /// went (a path, or `download` in a browser), or null when the host
  /// cannot save files.
  Future<String?> save(String name, Uint8List bytes) async => null;
}

/// Toasts and sharing.
class SurfaceFeedback {
  final _inApp = StreamController<String>.broadcast();

  /// Toasts for [SurfaceScope] to draw, from hosts without their own.
  Stream<String> get inAppToasts => _inApp.stream;

  /// Shows a short message: the host's toast where there is one
  /// ([Cap.toastNative]), otherwise an in-app one drawn by [SurfaceScope].
  Future<void> toast(String message) async => _inApp.add(message);

  /// Shares [text] through the system share sheet ([Cap.shareNative]).
  /// Without one it copies the text and says so. Returns whether the share
  /// sheet opened.
  Future<bool> share(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    await toast('Copied to the clipboard');
    return false;
  }
}

/// The host's look.
class SurfaceTheme {
  /// Material You colours the host publishes (`primary`, `onPrimary`,
  /// `surface`...), empty when it does not ([Cap.themeHostColors]).
  final ValueNotifier<Map<String, Color>> hostColors = ValueNotifier(const {});

  /// Whether the host is in dark mode, when it says; null to follow the
  /// platform brightness Flutter already reports.
  bool? get darkMode => null;
}

/// An installed app.
class AppPackage {
  const AppPackage({
    required this.packageName,
    this.label,
    this.versionName,
    this.system = false,
  });

  final String packageName;
  final String? label;
  final String? versionName;
  final bool system;
}

class SurfacePackages {
  /// Installed apps, user apps unless [system]. Empty where the host cannot
  /// list them ([Cap.packagesList]).
  Future<List<AppPackage>> list({bool system = false}) async => const [];
}

class SurfaceShell {
  /// Runs [command] in a shell (root on WebUI hosts). Without a shell it
  /// answers exit code 127. On hosts without [Cap.shellExecAsync] the page
  /// freezes until the command ends.
  Future<ExecResult> exec(
    String command, {
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 30),
  }) async => const ExecResult.unavailable();
}
