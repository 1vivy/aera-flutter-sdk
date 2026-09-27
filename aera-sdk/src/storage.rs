//! Where an app can keep files.
//!
//! Inside AERA the jail binds two writable directories. Outside AERA (on a
//! PC, under the simulator) the same calls return folders under
//! `$XDG_DATA_HOME/aera-flutter` so apps behave the same in development.

use std::path::PathBuf;

fn dev_root() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(std::env::temp_dir);
    base.join("aera-flutter")
}

fn existing_or_dev(jail: &str, dev: &str) -> PathBuf {
    let path = PathBuf::from(jail);
    if crate::env::in_recovery() && path.is_dir() {
        return path;
    }
    let path = dev_root().join(dev);
    let _ = std::fs::create_dir_all(&path);
    path
}

/// Private storage that survives reboots. On the phone this is
/// `/data/aera-recovery/browser/profile`, which only this app (and AERA
/// Browser, which shares the slot) can see.
pub fn app_data_dir() -> PathBuf {
    existing_or_dev("/profile", "profile")
}

/// The shared downloads folder, `/sdcard/AERA/Downloads` on the phone. Files
/// written here are visible to the user in AERA's Files app and over MTP.
pub fn downloads_dir() -> PathBuf {
    existing_or_dev("/downloads", "downloads")
}

/// Scratch space in RAM, cleared when the app closes.
pub fn temp_dir() -> PathBuf {
    std::env::temp_dir()
}
