# aera-flutter-sdk (generic-host branch)

Rust crate (`aera-sdk`) exposing what a Flutter app running on AERA Recovery's
generic pixel + GPU plugin host can reach: recovery language, private and
shared storage, device basics and speaker audio. Apps run as root with
recovery's own access, like every generic plugin.

> **The host is not released yet.** Paths and sockets the host will hand out
> are assumed (marked `ASSUMED` in the source) and will change to match it.
> What we need from the host is tracked in
> [aera-flutter-demo#1](https://github.com/1vivy/aera-flutter-demo/issues/1).
> The `main` branch targets the browser-slot stopgap.

Apps made from [aera-flutter-template](https://github.com/1vivy/aera-flutter-template/tree/generic-host)
call it through flutter_rust_bridge. See `aera-sdk/src/lib.rs` for the table of
doors.

Everything works on a PC too: storage falls back to `$XDG_DATA_HOME/aera-flutter`
and `in_recovery()` returns false.
