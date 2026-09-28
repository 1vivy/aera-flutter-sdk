/// AERA Recovery's own system features for Flutter apps: the back gesture,
/// the top bar and the keyboard.
///
/// Wrap the app once, and Back pops routes the way it does on Android:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => AeraScope(child: child!),
///   ...
/// )
/// ```
///
/// Everything else is on [AeraSystem.instance].
library;

export 'src/scope.dart';
export 'src/system.dart';
