# aera-flutter-sdk

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
