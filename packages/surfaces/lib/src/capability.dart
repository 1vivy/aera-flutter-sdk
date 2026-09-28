/// Names of the things a host may or may not offer.
///
/// Capabilities are fine-grained on purpose: a new host version, or a bug
/// workaround, changes detection, never app code. Check them with
/// `Surface.instance.info.has(Cap.exit)`.
abstract final class Cap {
  /// The host hands Back to the app, which decides (WebUI X with
  /// `backInterceptor: "javascript"`, AERA's edge gesture, Android).
  static const backIntercept = 'back.intercept';

  /// Back walks the page history; the app sees it as a route pop but cannot
  /// keep the host from closing once history runs out (KernelSU family).
  static const backHistory = 'back.history';

  /// The app can close itself.
  static const exit = 'exit';

  /// Safe-area insets are known.
  static const insets = 'insets';

  /// Insets update while the app runs (rotation, cutouts, bars).
  static const insetsLive = 'insets.live';

  /// The keyboard's height is reported.
  static const keyboardInset = 'keyboard.inset';

  /// The app can hide the host's bars.
  static const fullscreen = 'fullscreen';

  /// The app can pick light or dark status bar icons.
  static const statusBarStyle = 'statusbar.style';

  /// Pause and resume events arrive.
  static const lifecycle = 'lifecycle';

  /// Stored text survives the app being cleared from recents.
  static const storagePersistent = 'storage.persistent';

  /// Storage lives in root-owned files outside the host app, so it survives
  /// switching root managers or clearing their data.
  static const storageRoot = 'storage.root';

  /// A system file picker is available.
  static const filesPick = 'files.pick';

  /// Files can be saved where the user finds them (Downloads).
  static const filesSave = 'files.save';

  /// Toasts are the host's own; otherwise [SurfaceScope] shows them in-app.
  static const toastNative = 'toast.native';

  /// The system share sheet is available.
  static const shareNative = 'share.native';

  /// The host publishes its colour scheme (Material You).
  static const themeHostColors = 'theme.hostColors';

  /// Installed apps can be listed.
  static const packagesList = 'packages.list';

  /// App labels and versions are available, not just package names.
  static const packagesInfo = 'packages.info';

  /// Shell commands run (as root on WebUI hosts).
  static const shellExec = 'shell.exec';

  /// Shell commands run without freezing the UI. Without it (KernelSU,
  /// Next, SukiSU, APatch, the standalone host) every command blocks the page
  /// until it ends: keep them short and use ops jobs for anything long.
  static const shellExecAsync = 'shell.exec.async';

  /// Commands run as root.
  static const shellRoot = 'shell.root';

  /// The app's ops run (worker binary or in-process).
  static const opsCall = 'ops.call';

  /// Long ops run as jobs with progress and cancel.
  static const opsJobs = 'ops.jobs';

  /// The app's Rust core is loaded (FRB natively, plain wasm on the web).
  static const coreRust = 'core.rust';

  /// Every capability, for listings such as a host report.
  static const all = [
    backIntercept,
    backHistory,
    exit,
    insets,
    insetsLive,
    keyboardInset,
    fullscreen,
    statusBarStyle,
    lifecycle,
    storagePersistent,
    storageRoot,
    filesPick,
    filesSave,
    toastNative,
    shareNative,
    themeHostColors,
    packagesList,
    packagesInfo,
    shellExec,
    shellExecAsync,
    shellRoot,
    opsCall,
    opsJobs,
    coreRust,
  ];

  /// A short human description of [capability].
  static String describe(String capability) => switch (capability) {
    backIntercept => 'Back goes to the app',
    backHistory => 'Back walks page history',
    exit => 'App can close itself',
    insets => 'Safe-area insets',
    insetsLive => 'Insets update live',
    keyboardInset => 'Keyboard height',
    fullscreen => 'Full screen',
    statusBarStyle => 'Status bar icon style',
    lifecycle => 'Pause and resume events',
    storagePersistent => 'Persistent storage',
    storageRoot => 'Root-owned storage',
    filesPick => 'System file picker',
    filesSave => 'Save to Downloads',
    toastNative => 'Host toasts',
    shareNative => 'Share sheet',
    themeHostColors => 'Host colour scheme',
    packagesList => 'List installed apps',
    packagesInfo => 'App labels and versions',
    shellExec => 'Shell commands',
    shellExecAsync => 'Commands without freezing',
    shellRoot => 'Root shell',
    opsCall => 'Ops calls',
    opsJobs => 'Ops jobs with progress',
    coreRust => 'Rust core',
    _ => capability,
  };
}
