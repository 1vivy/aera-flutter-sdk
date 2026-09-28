/// The AERA Recovery backend for `package:surfaces`.
///
/// Pass [AeraBackend] to `Surface.init`. It matches only inside AERA (or its
/// PC simulator), so apps list it unconditionally.
library;

export 'src/backend_stub.dart' if (dart.library.io) 'src/backend_io.dart';
