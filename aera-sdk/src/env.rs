//! The environment AERA starts the app in.
//!
//! The app targets AERA's generic pixel + GPU plugin host, which is not
//! released yet. Like every generic plugin it is a recovery module: root, in
//! recovery's own filesystem, with recovery's access. Host API 2 already sets
//! `AERA_HOST_API`, `AERA_PLUGIN_ROOT` and `AERA_LOCALE`; the pixel host is
//! assumed to keep them.

use std::path::{Path, PathBuf};

/// Host API version AERA started the app with, or `None` outside AERA (and
/// outside `aera-host-sim`).
pub fn host_api() -> Option<u32> {
    std::env::var("AERA_HOST_API").ok()?.parse().ok()
}

/// True when running inside AERA Recovery on a phone rather than on a PC.
///
/// `aera-host-sim` sets the same variables AERA does, so this also checks for
/// the phone's GPU node.
pub fn in_recovery() -> bool {
    host_api().is_some() && Path::new("/dev/kgsl-3d0").exists()
}

/// Where AERA extracted the app's payload. Bundled resources live here.
pub fn plugin_root() -> PathBuf {
    std::env::var_os("AERA_PLUGIN_ROOT").map(PathBuf::from).unwrap_or_else(|| "/".into())
}

/// AERA's selected language, such as `de_DE` or `zh_CN`. Falls back to `en`.
pub fn locale() -> String {
    std::env::var("AERA_LOCALE").ok().filter(|l| !l.is_empty()).unwrap_or_else(|| "en".into())
}

/// Language part of [`locale`], such as `de`.
pub fn language() -> String {
    locale().split(['_', '-']).next().unwrap_or("en").to_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn language_splits_locale() {
        std::env::set_var("AERA_LOCALE", "zh_CN");
        assert_eq!(super::language(), "zh");
        std::env::remove_var("AERA_LOCALE");
        assert_eq!(super::locale(), "en");
    }

    #[test]
    fn host_api_reads_environment() {
        std::env::set_var("AERA_HOST_API", "3");
        assert_eq!(super::host_api(), Some(3));
        std::env::remove_var("AERA_HOST_API");
        assert_eq!(super::host_api(), None);
    }
}
