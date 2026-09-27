//! What a Flutter app running inside AERA Recovery can reach.
//!
//! Apps built from the AERA Flutter template run on AERA's generic pixel +
//! GPU plugin host. Like every generic plugin the app is a recovery module:
//! it runs as root in recovery's own filesystem, so partitions, `/data`,
//! `/sys` and recovery's tools are reachable directly. The host is not
//! released yet, so the doors below marked *assumed* are guesses that will
//! change to match it; the rest come from Host API 2
//! (`aeraui/features/plugin_api/` in AERA-Recovery/android_bootable_recovery).
//!
//! | Door | Where | Module |
//! | --- | --- | --- |
//! | Host API version, payload root | `AERA_HOST_API`, `AERA_PLUGIN_ROOT` | [`env`] |
//! | Recovery language | `AERA_LOCALE` | [`env`] |
//! | Private persistent storage (assumed) | `AERA_PLUGIN_DATA` | [`storage`] |
//! | Shared downloads folder (assumed) | `AERA_DOWNLOADS_DIR`, `/sdcard/AERA/Downloads` | [`storage`] |
//! | Scratch space | `TMPDIR` | [`storage`] |
//! | Speaker output, 48 kHz stereo (assumed) | abstract socket named in `AERA_AUDIO_SOCKET` | [`audio`] |
//! | Network | recovery's Wi-Fi route | use `dart:io` or any Rust client |
//! | Kernel, RAM, CPUs | `uname`, `sysinfo` | [`device`] |

pub mod audio;
pub mod device;
pub mod env;
pub mod storage;
