import 'package:flutter/foundation.dart';

import 'capability.dart';
import 'core.dart';
import 'host.dart';
import 'ops.dart';
import 'surface.dart';
import 'io/io_stub.dart' if (dart.library.io) 'io/io_native.dart' as io;

/// The surface when no backend claims the host: desktop builds, regular
/// Android or iOS builds, tests.
///
/// With `dart:io` it keeps storage in the app data folder, saves to
/// Downloads and runs shell commands with `sh -c`. Ops and the Rust core
/// come from [SurfaceConfig.nativeOps] and [SurfaceConfig.nativeCore]. On
/// the web without the WebUI backend it keeps everything in memory.
class FallbackSurface {
  FallbackSurface._();

  static Future<Surface> create(SurfaceConfig config) async {
    final services = io.createServices(config);
    final ops = config.nativeOps;
    final core = config.nativeCore;
    final capabilities = {
      ...services.capabilities,
      if (ops != null) Cap.opsCall,
      if (ops != null && ops.supportsJobs) Cap.opsJobs,
      if (core != null) Cap.coreRust,
    };
    return Surface(
      info: HostInfo(
        kind: services.kind,
        name: services.name,
        tier: services.kind.name,
        engine: kIsWeb ? 'web' : 'Flutter ${services.kind.name}',
        capabilities: capabilities,
        details: services.details,
      ),
      config: config,
      storage: services.storage,
      files: services.files,
      shell: services.shell,
      ops: ops == null ? Ops.unavailable('The app passed no nativeOps') : Ops(ops),
      core: core == null
          ? Core.unavailable('The app passed no nativeCore')
          : Core(core),
    );
  }
}
