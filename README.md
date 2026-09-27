# aera-flutter-sdk

Rust crate (`aera-sdk`) exposing what a Flutter app running inside AERA
Recovery's browser slot can reach: recovery language, private and shared
storage, device basics, and speaker audio through AERA's audio bridge.

Apps made from [aera-flutter-template](https://github.com/1vivy/aera-flutter-template)
call it through flutter_rust_bridge. See `aera-sdk/src/lib.rs` for the table of
what the jail allows and what it keeps out.

Everything works on a PC too: storage falls back to `$XDG_DATA_HOME/aera-flutter`
and `in_recovery()` returns false.
