/// `dart:io` building blocks for native backends (storage in files, a
/// Downloads folder, `sh -c`). Import only from code that runs natively.
library;

export 'src/io/io_native.dart' show IoStorage, IoFiles, IoShell, desktopPaths;
