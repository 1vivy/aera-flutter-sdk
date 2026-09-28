/// The web backend for `package:surfaces`: KernelSU-family module WebUIs,
/// WebUI X, and plain browsers.
///
/// Pass [WebUiBackend] to `Surface.init`. Off the web it never matches, so
/// apps list it unconditionally.
library;

export 'src/backend_stub.dart' if (dart.library.js_interop) 'src/backend_web.dart';
