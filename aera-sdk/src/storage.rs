//! Where an app can keep files.
//!
//! ASSUMED: the pixel host names a private persistent directory in
//! `AERA_PLUGIN_DATA` and the shared downloads folder in `AERA_DOWNLOADS_DIR`.
//! A privileged app can also reach `/sdcard/AERA/Downloads` directly. Outside
//! AERA (on a PC, under the simulator) the same calls return folders under
//! `$XDG_DATA_HOME/aera-flutter` so apps behave the same in development.

use std::path::{Path, PathBuf};

fn dev_root() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(std::env::temp_dir);
    base.join("aera-flutter")
}

fn from_host(variable: &str, fallback: Option<&str>, dev: &str) -> PathBuf {
    if crate::env::in_recovery() {
        let host = std::env::var_os(variable).map(PathBuf::from);
        let direct = fallback.filter(|_| crate::env::privileged()).map(PathBuf::from);
        if let Some(path) = host.into_iter().chain(direct).find(|p| p.is_dir()) {
            return path;
        }
    }
    let path = dev_root().join(dev);
    let _ = std::fs::create_dir_all(&path);
    path
}

/// Private storage that survives reboots and only this app can see.
pub fn app_data_dir() -> PathBuf {
    from_host("AERA_PLUGIN_DATA", None, "profile")
}

/// The shared downloads folder, `/sdcard/AERA/Downloads` on the phone. Files
/// written here are visible to the user in AERA's Files app and over MTP.
pub fn downloads_dir() -> PathBuf {
    from_host("AERA_DOWNLOADS_DIR", Some("/sdcard/AERA/Downloads"), "downloads")
}

/// Scratch space in RAM, cleared when the app closes.
pub fn temp_dir() -> PathBuf {
    std::env::temp_dir()
}

/// A file bundled in the app's payload, such as `usr/share/app/data.bin`.
pub fn bundled(relative: impl AsRef<Path>) -> PathBuf {
    crate::env::plugin_root().join(relative)
}
