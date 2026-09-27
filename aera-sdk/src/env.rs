//! The environment AERA starts the app in.

use std::path::Path;

/// True when running inside AERA's browser jail rather than on a PC.
///
/// The jail's root is the app payload, so the embedder sits at
/// `/usr/bin/aera-browser-worker` and `/dev/kgsl-3d0` is the only GPU node.
/// On a PC under `aera-host-sim` neither holds.
pub fn in_recovery() -> bool {
    Path::new("/usr/bin/aera-browser-worker").is_file() && Path::new("/dev/kgsl-3d0").exists()
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
}
