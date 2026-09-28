import '../host.dart';
import '../services.dart';
import '../surface.dart';

/// Services the fallback surface can offer on this platform.
class FallbackServices {
  FallbackServices({
    required this.kind,
    required this.name,
    this.capabilities = const {},
    this.details = const {},
    SurfaceStorage? storage,
    SurfaceFiles? files,
    SurfaceShell? shell,
  }) : storage = storage ?? SurfaceStorage(),
       files = files ?? SurfaceFiles(),
       shell = shell ?? SurfaceShell();

  final HostKind kind;
  final String name;
  final Set<String> capabilities;
  final Map<String, String> details;
  final SurfaceStorage storage;
  final SurfaceFiles files;
  final SurfaceShell shell;
}

FallbackServices createServices(SurfaceConfig config) =>
    FallbackServices(kind: HostKind.headless, name: 'Unknown host');
