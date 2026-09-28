import 'package:surfaces/surfaces.dart';

/// Recognises AERA Recovery. Without `dart:io` it never matches.
class AeraBackend extends SurfaceBackend {
  const AeraBackend();

  @override
  Future<Surface?> tryCreate(SurfaceConfig config) async => null;
}
