//! What a Flutter app running inside AERA Recovery can reach.
//!
//! Apps built from the AERA Flutter template run in AERA's browser jail
//! (`aeraui/features/browser/jail_main.cpp` in AERA-Recovery/
//! android_bootable_recovery): a chroot of the app's own payload, a dedicated
//! UID with no capabilities, a seccomp filter, and these doors out:
//!
//! | Door | Where | Module |
//! | --- | --- | --- |
//! | Private persistent storage | `/profile` | [`storage`] |
//! | Shared downloads folder | `/downloads` (`/sdcard/AERA/Downloads`) | [`storage`] |
//! | Scratch space, 512 MB RAM | `/tmp` | [`storage`] |
//! | Speaker output, 48 kHz stereo | abstract socket `aera-browser-audio-v1` | [`audio`], [`speaker`] (shared, mixed, stays connected) |
//! | Network (TCP, UDP; no listening) | recovery's Wi-Fi route | use `dart:io` or any Rust client |
//! | Recovery language | `AERA_LOCALE` | [`env`] |
//! | Kernel, RAM, CPUs | `uname`, `sysinfo`, affinity | [`device`] |
//!
//! Everything else (partitions, `/data`, `/sys`, Binder, recovery
//! operations) is deliberately outside the jail.

pub mod audio;
pub mod device;
pub mod env;
pub mod speaker;
pub mod storage;
