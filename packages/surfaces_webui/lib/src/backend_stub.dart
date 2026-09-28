import 'package:surfaces/surfaces.dart';

/// Recognises WebUI hosts and plain browsers. Off the web it never matches.
class WebUiBackend extends SurfaceBackend {
  const WebUiBackend();

  @override
  Future<Surface?> tryCreate(SurfaceConfig config) async => null;
}
