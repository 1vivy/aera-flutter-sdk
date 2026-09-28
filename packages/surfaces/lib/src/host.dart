/// Which kind of shell the app is in.
enum HostKind {
  /// A root manager's module WebUI: KernelSU, SukiSU, KernelSU Next, APatch,
  /// KsuWebUIStandalone or WebUI X (MMRL, WebUI X Portable).
  webui,

  /// A plain web page with no host bridge: the bottom rung of the WebUI
  /// ladder, and a hosted web target for free.
  browser,

  /// AERA Recovery's app slot, on the AERA embedder.
  aera,

  /// A desktop build (Linux, macOS, Windows), mostly for development.
  desktop,

  /// A regular Android or iOS app.
  mobile,

  /// Tests, or nothing registered.
  headless,
}

/// What the app knows about its host, detected once at start.
class HostInfo {
  const HostInfo({
    required this.kind,
    required this.name,
    this.tier = '',
    this.version = '',
    this.engine = '',
    this.capabilities = const {},
    this.details = const {},
  });

  final HostKind kind;

  /// The host's name, such as `WebUI X Portable`, `KernelSU` or `AERA Recovery`.
  final String name;

  /// On the web: `webuix` (WebUI X), `webui` (the KernelSU WebUI bridge,
  /// whichever manager provides it) or `browser`. Elsewhere the kind's name.
  /// What a host can do is in [capabilities], never inferred from this.
  final String tier;

  /// The host's version, when it tells.
  final String version;

  /// What renders the app, such as `Chrome/130 (CanvasKit)` or `AERA embedder`.
  final String engine;

  /// Every [Cap] this host offers.
  final Set<String> capabilities;

  /// Anything else worth showing in a host report.
  final Map<String, String> details;

  bool has(String capability) => capabilities.contains(capability);

  /// 2 for WebUI X, 1 for the KernelSU WebUI bridge, 0 for a plain
  /// browser; -1 off the web.
  int get webTierRank => switch (tier) {
    'webuix' => 2,
    'webui' => 1,
    'browser' => 0,
    _ => -1,
  };

  HostInfo copyWith({
    Set<String>? capabilities,
    Map<String, String>? details,
    String? engine,
  }) => HostInfo(
    kind: kind,
    name: name,
    tier: tier,
    version: version,
    engine: engine ?? this.engine,
    capabilities: capabilities ?? this.capabilities,
    details: details ?? this.details,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'name': name,
    'tier': tier,
    'version': version,
    'engine': engine,
    'capabilities': capabilities.toList()..sort(),
    'details': details,
  };

  @override
  String toString() => '$name ($tier${version.isEmpty ? '' : ' $version'})';
}
