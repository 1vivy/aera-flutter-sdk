import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// AERA's top bar, back gesture and keyboard, as seen from the app.
///
/// Talks to the embedder over the `aera/system` channel. Outside AERA (for
/// example `flutter run -d linux`) nothing answers; calls then do nothing
/// and no events arrive.
class AeraSystem {
  AeraSystem._() {
    channel.setMethodCallHandler(_handle);
  }

  /// The one instance.
  static final AeraSystem instance = AeraSystem._();

  /// The channel the embedder listens on.
  static const MethodChannel channel = MethodChannel(
    'aera/system',
    JSONMethodCodec(),
  );

  final _forward = StreamController<void>.broadcast();
  final _reload = StreamController<void>.broadcast();
  final _stop = StreamController<void>.broadcast();
  final _open = StreamController<String>.broadcast();
  final _zoom = StreamController<int>.broadcast();

  /// Whether AERA's keyboard is up. While it is, the app's bottom view inset
  /// ([MediaQueryData.viewInsets]) is the keyboard's height, so a [Scaffold]
  /// keeps the focused field above it, as on Android.
  final ValueNotifier<bool> keyboardVisible = ValueNotifier(false);

  /// The top bar's Forward button. It is enabled while
  /// [setNavigationState] says the app can go forward.
  Stream<void> get onForward => _forward.stream;

  /// The top bar's Reload button.
  Stream<void> get onReload => _reload.stream;

  /// AERA's Stop request.
  Stream<void> get onStop => _stop.stream;

  /// An address typed into the top bar, or the Home button (which opens the
  /// homepage set in AERA's browser settings; Home does nothing when none
  /// is set). AERA only passes on `http://` and `https://` addresses.
  Stream<String> get onOpen => _open.stream;

  /// A two-finger pinch on the app, as a zoom level from 50 to 300 percent.
  /// AERA turns pinches into zoom levels and does not send the fingers.
  Stream<int> get onZoom => _zoom.stream;

  /// Tells AERA whether Back and Forward have somewhere to go.
  ///
  /// AERA sends the back gesture, and enables its Back button, only while
  /// [canGoBack] is true. Otherwise the gesture leaves the app. [AeraScope]
  /// keeps [canGoBack] in step with the app's navigator, so most apps only
  /// ever set [canGoForward].
  Future<void> setNavigationState({bool? canGoBack, bool? canGoForward}) =>
      _invoke('setNavigationState', {
        'canGoBack': ?canGoBack,
        'canGoForward': ?canGoForward,
      });

  /// Shows [address] in AERA's top bar and [progress] (0 to 100) as its
  /// loading progress. AERA shows only `http(s)://` addresses and
  /// `aera://start`.
  Future<void> setStatus({String? address, int? progress}) =>
      _invoke('setStatus', {'address': ?address, 'progress': ?progress});

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not inside AERA.
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'onForward':
        _forward.add(null);
      case 'onReload':
        _reload.add(null);
      case 'onStop':
        _stop.add(null);
      case 'onOpen':
        _open.add(call.arguments as String);
      case 'onZoom':
        _zoom.add(call.arguments as int);
      case 'onKeyboard':
        keyboardVisible.value =
            (call.arguments as Map<Object?, Object?>)['visible'] == true;
    }
    return null;
  }

  /// Feeds [call] to the handler as if the embedder had sent it.
  @visibleForTesting
  Future<void> debugReceive(MethodCall call) => _handle(call);
}
