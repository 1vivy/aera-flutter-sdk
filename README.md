# surfaces (in aera-flutter-sdk)

One Flutter app, every surface: a **KernelSU / WebUI X module**, a **plain web
page**, an **AERA Recovery app** and a **desktop app**, from the same code.
Apps ask for capabilities, never for the host, and every feature has a
documented fallback where a host lacks it.

This branch builds the `surfaces` workspace inside `aera-flutter-sdk` until it
moves to its own repository (planned: `p0g-stack/surfaces`). The AERA pieces
that were here (`aera-sdk`, `aera_flutter`) stay, and `surfaces_aera` builds on
them.

| Path | What it is |
| --- | --- |
| `packages/surfaces` | The API apps import: `Surface.instance` (window, navigation, lifecycle, storage, files, feedback, theme, packages, shell, ops, core), `SurfaceScope`, capabilities. Desktop and test fallback. |
| `packages/surfaces_webui` | Web backend. Detects WebUI X, the KernelSU WebUI bridge (any manager) or a plain browser, and each optional bridge method one by one; wraps `ksu.*`, `webui.*`, `$<module>.*`, WX events, host insets and Monet colours; loads the Rust core as plain wasm. |
| `packages/surfaces_aera` | AERA backend on `aera_flutter` (`AeraScope`, safe area, keyboard) with in-process ops and core. |
| `packages/surfaces_ui` | Shared look: `SurfacesApp`, a theme that takes host colours, spacing tokens, `HostBanner`, `CapabilityRow`, `FallbackNote`. |
| `crates/surfaces-core` | Pure Rust for every target: the ops protocol, shell quoting, WebUI naming rules, SHA-256, and the core ABI (`export_wasm_core!`). |
| `crates/surfaces-ops` | `Handler` trait, built-in ops (`sys.info`, `fs.stat`, `fs.list`, `fs.hash`, `sys.wait`), an in-process job runner, and the worker binary protocol used over `ksu.exec`. |
| `tools/cli` | `surfaces` dev CLI: `build webui|web|aera|linux|all`, `serve --host webuix|webui|webui-min|browser` (fake bridge in any browser), `sim` (AERA simulator), `doctor`. |
| `aera-sdk`, `aera_flutter` | AERA Recovery's Rust SDK and Flutter system package (unchanged). |

## The three abstractions

- **Platform** (`Surface`, Dart): what the host shell gives the app.
- **Core** (Rust, `Surface.instance.core`): fast, pure work, synchronous. On
  native targets through flutter_rust_bridge; on the web as a plain wasm
  module with a JSON ABI. flutter_rust_bridge's own web mode links shared
  memory, which needs cross-origin isolation, and no WebUI host can send
  COOP/COEP headers, so the web path avoids it.
- **Ops** (Rust, `Surface.instance.ops`): privileged or long work, defined once
  as a `Handler`. On WebUI it runs as root in the module's worker binary over
  `ksu.exec`, with long work as detached jobs polled every 250 ms (a command
  blocks the whole page on every host but WebUI X). On AERA and desktop it
  runs in-process.

## Using it

```yaml
dependencies:
  surfaces: {git: {url: https://github.com/1vivy/aera-flutter-sdk, path: packages/surfaces}}
  surfaces_ui: {git: {url: https://github.com/1vivy/aera-flutter-sdk, path: packages/surfaces_ui}}
  surfaces_webui: {git: {url: https://github.com/1vivy/aera-flutter-sdk, path: packages/surfaces_webui}}
  surfaces_aera: {git: {url: https://github.com/1vivy/aera-flutter-sdk, path: packages/surfaces_aera}}
```

```dart
await Surface.init(
  const SurfaceConfig(appId: 'my_app'),
  backends: const [WebUiBackend(), AeraBackend()],
);
runApp(const SurfacesApp(title: 'My App', home: Home()));
```

Start from [aera-flutter-template](https://github.com/1vivy/aera-flutter-template)
(becoming `template-app`), which has every platform folder, the Rust
workspace (native bridge, core, worker) and `surfaces.yaml` in place. The
demo that exercises every affordance is
[aera-flutter-demo](https://github.com/1vivy/aera-flutter-demo).

## What belongs here

surfaces is the host layer only: detecting the host, the Dart services with
their fallbacks, the core/ops protocol and worker plumbing, and the build
CLI. Anything an app does (flashing, backups, its own backends such as
fastboot vs `dd`) lives in that app's repo, in its own Rust workspace; the
template shows where, and the demo shows how an app switches backends
behind one op.

## Fallbacks by host

There are two WebUI platforms: **WebUI X** and the **KernelSU WebUI**
bridge (`window.ksu`), which KernelSU, SukiSU, KernelSU Next, APatch and
KsuWebUIStandalone all provide. Managers differ only in which optional
`ksu` methods they ship, so each feature below follows the method, not the
manager.

| Feature | WebUI X | KernelSU WebUI | Browser | AERA |
| --- | --- | --- | --- | --- |
| Back | `WX_ON_BACK` → route pop | history → route pop | history | edge gesture |
| Exit at root | `webui.exit()` | `ksu.exit()` if present, else the host closes when history runs out | – | AERA leaves |
| Insets | CSS vars + `WX_ON_INSETS` | `insets.css` with `enableEdgeToEdge`/`enableInsets`, else none | none | `aera/system` |
| Toast | host | `ksu.toast` | in-app | in-app |
| Commands | async | **blocks the page** | none | `sh` if present |
| Packages | `pm` via shell | `listPackages` + `getPackagesInfo` if present, else `pm` | – | – |
| Storage | root files | root files | localStorage | `/profile` |
| Ops | worker | worker | – | in-process |
| Core | wasm | wasm | wasm | FRB |

## aera-sdk (AERA Recovery)

Rust crate (`aera-sdk`) exposing what a Flutter app running inside AERA
Recovery's browser slot can reach: recovery language, private and shared
storage, device basics, and speaker audio through AERA's audio bridge.

Apps made from [aera-flutter-template](https://github.com/1vivy/aera-flutter-template)
call it through flutter_rust_bridge. See `aera-sdk/src/lib.rs` for the table of
what the jail allows and what it keeps out.

Everything works on a PC too: storage falls back to `$XDG_DATA_HOME/aera-flutter`
and `in_recovery()` returns false.

## Dart package: `aera_flutter`

`aera_flutter/` is a Flutter package for AERA's own system features, used
the way Flutter apps use Android's:

- **Back**: wrap the app with `AeraScope` in `MaterialApp.builder`. AERA's
  edge-back gesture and top-bar Back then pop routes (and respect `PopScope`),
  and leave the app from its first page.
- **Keyboard**: text fields open AERA's keyboard, and while it is up the app
  gets a bottom view inset, so `Scaffold` keeps the focused field visible.
  `AeraSystem.instance.keyboardVisible` follows it.
- **Top bar**: `onForward`, `onReload`, `onOpen` (typed addresses and Home),
  `onZoom` (pinch), and `setNavigationState` / `setStatus` to enable Forward
  and show an address and progress.

```yaml
dependencies:
  aera_flutter:
    git:
      url: https://github.com/1vivy/aera-flutter-sdk
      path: aera_flutter
```
