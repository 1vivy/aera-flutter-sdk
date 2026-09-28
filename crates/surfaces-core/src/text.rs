//! Shell quoting and WebUI naming rules.
//!
//! Every WebUI host pastes `cwd`, `env` and `spawn` arguments into a shell
//! line unescaped, so anything that reaches a shell is quoted here first.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;

/// Quotes `value` as one POSIX shell word.
///
/// ```
/// assert_eq!(surfaces_core::text::shell_quote("it's"), r#"'it'\''s'"#);
/// ```
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// Joins `words` into one shell line, quoting each.
pub fn shell_line<S: AsRef<str>>(words: &[S]) -> String {
    words.iter().map(|w| shell_quote(w.as_ref())).collect::<Vec<_>>().join(" ")
}

/// The id WebUI X uses to name a module's globals: every character outside
/// `[A-Za-z0-9_]` becomes `_`. Module `my-mod.x` gets `window.$my_mod_x`.
pub fn webui_module_global(module_id: &str) -> String {
    let sanitized: String = module_id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect();
    format!("${sanitized}")
}

/// WebUI X's file interface name: `$` + the first character upper-cased +
/// the second + `File`. Module `fake_bl_efisp` gets `window.$FaFile`.
pub fn webui_file_global(module_id: &str) -> Option<String> {
    let sanitized = &webui_module_global(module_id)[1..];
    let mut chars = sanitized.chars();
    let first = chars.next()?.to_ascii_uppercase();
    let second = chars.next()?;
    Some(format!("${first}{second}File"))
}

/// Reads `key=value` lines, as in a module's `module.prop`.
pub fn parse_prop(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            Some((key.trim().to_owned(), value.trim().to_owned()))
        })
        .collect()
}

/// Whether `id` is a valid KernelSU module id (`^[a-zA-Z][a-zA-Z0-9._-]+$`).
pub fn is_module_id(id: &str) -> bool {
    let mut chars = id.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic())
        && id.len() >= 2
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// `1536` → `1.5 KiB`.
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// URL-safe base64 without padding: safe inside a quoted shell word and a
/// URL. The worker reads requests in this form.
pub fn b64url_encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn b64url_decode(text: &str) -> Result<Vec<u8>, String> {
    URL_SAFE_NO_PAD.decode(text.trim()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_line(&["a b", "c"]), "'a b' 'c'");
    }

    #[test]
    fn webui_names() {
        assert_eq!(webui_module_global("fake_bl_efisp"), "$fake_bl_efisp");
        assert_eq!(webui_module_global("my-mod.x"), "$my_mod_x");
        assert_eq!(webui_file_global("fake_bl_efisp").unwrap(), "$FaFile");
        assert_eq!(webui_file_global("x"), None);
    }

    #[test]
    fn props_and_ids() {
        let props = parse_prop("id=demo\n# c\nname = Demo App \n\nbad");
        assert_eq!(props, vec![("id".into(), "demo".into()), ("name".into(), "Demo App".into())]);
        assert!(is_module_id("surfaces_demo"));
        assert!(!is_module_id("1abc"));
        assert!(!is_module_id("a b"));
    }

    #[test]
    fn bytes_and_b64() {
        assert_eq!(format_bytes(12), "12 B");
        assert_eq!(format_bytes(1536), "1.5 KiB");
        let encoded = b64url_encode(b"{\"op\":\"x\"}");
        assert_eq!(b64url_decode(&encoded).unwrap(), b"{\"op\":\"x\"}");
    }
}
