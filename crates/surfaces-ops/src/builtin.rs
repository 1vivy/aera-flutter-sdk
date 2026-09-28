//! Ops every surfaces app gets for free. Apps fall through to [`call`] for
//! ops they do not handle themselves.
//!
//! | Op | Input | Result |
//! | --- | --- | --- |
//! | `sys.info` | – | `os`, `arch`, `uid`, `pid`, `kernel`, `root` |
//! | `fs.stat` | `path` | `exists`, `kind`, `size`, `mode`, `modified` |
//! | `fs.list` | `path`, `limit` (200) | `entries` of `name`, `kind`, `size`; `truncated` |
//! | `fs.hash` | `path` | `sha256`, `size` (job: progress per MiB) |
//! | `sys.wait` | `seconds` (3) | `waited` (job: progress ten times a second) |
//!
//! File ops need a real file system, so on wasm they answer `unavailable`.

use crate::{input, JobCtx, OpError, Request};
use serde::Deserialize;
use serde_json::{json, Value};

pub fn call(request: &Request, job: &JobCtx) -> Result<Value, OpError> {
    match request.op.as_str() {
        "sys.info" => Ok(sys_info()),
        "fs.stat" => fs::stat(input(request)?),
        "fs.list" => fs::list(input(request)?),
        "fs.hash" => fs::hash(input(request)?, job),
        "sys.wait" => wait(input(request)?, job),
        other => Err(OpError::new("unknown-op", format!("No op named {other}"))),
    }
}

/// The names [`call`] answers, for capability listings.
pub const OPS: &[&str] = &["sys.info", "fs.stat", "fs.list", "fs.hash", "sys.wait"];

fn sys_info() -> Value {
    #[cfg(unix)]
    let (uid, kernel) = {
        let uid = unsafe { libc::geteuid() };
        let kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease")
            .map(|s| s.trim().to_owned())
            .unwrap_or_default();
        (Some(uid), kernel)
    };
    #[cfg(not(unix))]
    let (uid, kernel): (Option<u32>, String) = (None, String::new());
    json!({
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "uid": uid,
        "root": uid == Some(0),
        "pid": if cfg!(target_family = "wasm") { None } else { Some(std::process::id()) },
        "kernel": kernel,
    })
}

#[derive(Deserialize)]
struct Wait {
    #[serde(default = "three")]
    seconds: f64,
}

fn three() -> f64 {
    3.0
}

fn wait(args: Wait, job: &JobCtx) -> Result<Value, OpError> {
    let seconds = args.seconds.clamp(0.0, 600.0);
    let steps = (seconds * 10.0).round() as u32;
    for step in 0..steps {
        job.check()?;
        job.progress(step as f64 / steps as f64, format!("{:.1} s of {seconds:.1} s", step as f64 / 10.0));
        #[cfg(not(target_family = "wasm"))]
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Ok(json!({ "waited": seconds }))
}

#[derive(Deserialize)]
struct PathArg {
    path: String,
}

#[derive(Deserialize)]
struct ListArg {
    path: String,
    #[serde(default = "two_hundred")]
    limit: usize,
}

fn two_hundred() -> usize {
    200
}

#[cfg(not(target_family = "wasm"))]
mod fs {
    use super::*;
    use std::io::Read;

    fn kind(meta: &std::fs::Metadata) -> &'static str {
        let file_type = meta.file_type();
        if file_type.is_dir() {
            "dir"
        } else if file_type.is_symlink() {
            "link"
        } else if file_type.is_file() {
            "file"
        } else {
            "other"
        }
    }

    pub fn stat(args: PathArg) -> Result<Value, OpError> {
        let meta = match std::fs::symlink_metadata(&args.path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(json!({"exists": false})),
            Err(e) => return Err(OpError::io(e)),
        };
        #[cfg(unix)]
        let mode = {
            use std::os::unix::fs::PermissionsExt;
            Some(format!("{:o}", meta.permissions().mode() & 0o7777))
        };
        #[cfg(not(unix))]
        let mode: Option<String> = None;
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs());
        Ok(json!({
            "exists": true,
            "kind": kind(&meta),
            "size": meta.len(),
            "mode": mode,
            "modified": modified,
        }))
    }

    pub fn list(args: ListArg) -> Result<Value, OpError> {
        let mut entries = Vec::new();
        let mut truncated = false;
        let mut names: Vec<_> = std::fs::read_dir(&args.path)
            .map_err(OpError::io)?
            .filter_map(|e| e.ok())
            .collect();
        names.sort_by_key(|e| e.file_name());
        for entry in names {
            if entries.len() >= args.limit.min(2000) {
                truncated = true;
                break;
            }
            let meta = entry.metadata().ok();
            entries.push(json!({
                "name": entry.file_name().to_string_lossy(),
                "kind": meta.as_ref().map(kind).unwrap_or("other"),
                "size": meta.as_ref().map(|m| m.len()),
            }));
        }
        Ok(json!({ "entries": entries, "truncated": truncated }))
    }

    pub fn hash(args: PathArg, job: &JobCtx) -> Result<Value, OpError> {
        let mut file = std::fs::File::open(&args.path).map_err(OpError::io)?;
        let size = file.metadata().map_err(OpError::io)?.len();
        let mut digest = surfaces_core::hash::Sha256Stream::new();
        let mut buffer = vec![0u8; 1 << 20];
        let mut done = 0u64;
        loop {
            job.check()?;
            let read = file.read(&mut buffer).map_err(OpError::io)?;
            if read == 0 {
                break;
            }
            digest.update(&buffer[..read]);
            done += read as u64;
            let fraction = if size == 0 { 1.0 } else { done as f64 / size as f64 };
            job.progress(
                fraction,
                format!(
                    "{} of {}",
                    surfaces_core::text::format_bytes(done),
                    surfaces_core::text::format_bytes(size)
                ),
            );
        }
        Ok(json!({ "sha256": digest.finish_hex(), "size": done }))
    }
}

#[cfg(target_family = "wasm")]
mod fs {
    use super::*;

    pub fn stat(_: PathArg) -> Result<Value, OpError> {
        Err(OpError::unavailable("fs.stat"))
    }

    pub fn list(_: ListArg) -> Result<Value, OpError> {
        Err(OpError::unavailable("fs.list"))
    }

    pub fn hash(_: PathArg, _: &JobCtx) -> Result<Value, OpError> {
        Err(OpError::unavailable("fs.hash"))
    }
}

#[cfg(all(test, not(target_family = "wasm")))]
mod tests {
    use super::*;

    #[test]
    fn stat_list_hash() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), b"abc").unwrap();
        let path = dir.path().join("a.txt").to_string_lossy().into_owned();
        let stat = call(&Request::new("fs.stat", json!({ "path": path })), &JobCtx::none()).unwrap();
        assert_eq!(stat["kind"], "file");
        assert_eq!(stat["size"], 3);
        let list = call(
            &Request::new("fs.list", json!({ "path": dir.path() })),
            &JobCtx::none(),
        )
        .unwrap();
        assert_eq!(list["entries"][0]["name"], "a.txt");
        let hash = call(&Request::new("fs.hash", json!({ "path": path })), &JobCtx::none()).unwrap();
        assert_eq!(hash["sha256"], surfaces_core::hash::sha256_hex(b"abc"));
        let missing = call(&Request::new("fs.stat", json!({"path": "/nope/x"})), &JobCtx::none()).unwrap();
        assert_eq!(missing["exists"], false);
    }

    #[test]
    fn unknown_op() {
        let error = call(&Request::new("x.y", Value::Null), &JobCtx::none()).unwrap_err();
        assert_eq!(error.code, "unknown-op");
    }
}
