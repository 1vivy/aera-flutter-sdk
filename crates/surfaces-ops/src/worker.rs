//! The worker binary: an app's [`Handler`] behind a small command line, run
//! as root over `ksu.exec` on WebUI hosts.
//!
//! An app's worker is one line:
//!
//! ```ignore
//! fn main() { surfaces_ops::worker::main(MyHandler) }
//! ```
//!
//! Commands (each prints one JSON Envelope line on stdout and exits 0; the
//! Dart `WorkerTransport` in `package:surfaces` speaks this):
//!
//! ```text
//! worker call <b64url request>
//! worker start [--state DIR] <b64url request>   → {"ok":{"id":...}}
//! worker poll [--state DIR] <id>                → {"ok":JobStatus}
//! worker cancel [--state DIR] <id>
//! worker hello                                  → protocol and ops
//! ```
//!
//! `start` returns at once and leaves the job running detached (its own
//! session, no stdio), because `ksu.exec` blocks the whole page on KernelSU,
//! Next, SukiSU, APatch and the standalone host until the shell exits. The job
//! writes its status to `DIR/<id>.json`; `poll` reads it. `cancel` drops a
//! `DIR/<id>.cancel` marker the job notices at its next check. A job whose
//! process is gone while its status still says running is reported failed.

use crate::{dispatch, Envelope, Handler, JobCtx, JobSink, JobStatus, OpError, Request};
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};
use surfaces_core::text::b64url_decode;

/// Protocol version `hello` reports. Bump when commands change.
pub const PROTOCOL: u32 = 1;

/// Runs the worker command line and exits.
pub fn main(handler: impl Handler) -> ! {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let envelope = run(&handler, &args);
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{}", envelope.to_json());
    let _ = stdout.flush();
    std::process::exit(0)
}

/// Runs one command line, for tests and for apps that add their own
/// commands around it.
pub fn run(handler: &dyn Handler, args: &[String]) -> Envelope {
    Envelope::from_result(command(handler, args))
}

fn command(handler: &dyn Handler, args: &[String]) -> Result<serde_json::Value, OpError> {
    let (state, rest) = state_dir(args)?;
    let rest: Vec<&str> = rest.iter().map(String::as_str).collect();
    match rest.as_slice() {
        ["hello"] => Ok(json!({
            "protocol": PROTOCOL,
            "builtins": crate::builtin::OPS,
            "pid": std::process::id(),
            "uid": unsafe { libc::geteuid() },
        })),
        ["call", request] => dispatch(handler, &decode(request)?, &JobCtx::none()),
        ["start", request] => start(&state, &decode(request)?),
        ["poll", id] => poll(&state, id),
        ["cancel", id] => cancel(&state, id),
        ["run", id] => {
            run_job(handler, &state, id);
            Ok(json!(null))
        }
        _ => Err(OpError::new(
            "usage",
            "worker call|start <b64url request> | poll|cancel <id> | hello  [--state DIR]",
        )),
    }
}

fn state_dir(args: &[String]) -> Result<(PathBuf, Vec<String>), OpError> {
    let mut state = None;
    let mut rest = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--state" {
            let dir = iter.next().ok_or_else(|| OpError::new("usage", "--state needs a directory"))?;
            state = Some(PathBuf::from(dir));
        } else {
            rest.push(arg.clone());
        }
    }
    let state = state.unwrap_or_else(|| {
        let name = std::env::current_exe()
            .ok()
            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
            .unwrap_or_else(|| "worker".into());
        std::env::temp_dir().join(format!("surfaces-{name}"))
    });
    Ok((state, rest))
}

fn decode(encoded: &str) -> Result<Request, OpError> {
    let bytes = b64url_decode(encoded).map_err(|e| OpError::new("request", e))?;
    let text = String::from_utf8(bytes).map_err(|e| OpError::new("request", e.to_string()))?;
    Request::from_json(&text)
}

fn valid_id(id: &str) -> Result<(), OpError> {
    if id.is_empty() || id.len() > 64 || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(OpError::new("request", "Bad job id"));
    }
    Ok(())
}

fn path(state: &Path, id: &str, suffix: &str) -> PathBuf {
    state.join(format!("{id}{suffix}"))
}

fn write_atomic(target: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = target.with_extension("tmp");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(temporary, target)
}

fn write_status(state: &Path, status: &JobStatus) {
    let bytes = serde_json::to_vec(status).expect("a status always serialises");
    let _ = write_atomic(&path(state, &status.id, ".json"), &bytes);
}

/// Deletes job files older than a day.
fn sweep(state: &Path) {
    let Ok(entries) = std::fs::read_dir(state) else { return };
    let day = Duration::from_secs(24 * 3600);
    for entry in entries.flatten() {
        let old = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| SystemTime::now().duration_since(t).ok())
            .is_some_and(|age| age > day);
        if old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn start(state: &Path, request: &Request) -> Result<serde_json::Value, OpError> {
    std::fs::create_dir_all(state).map_err(OpError::io)?;
    sweep(state);
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let id = format!("j{nanos:x}-{}", std::process::id());
    let request_bytes = serde_json::to_vec(request).map_err(OpError::io)?;
    std::fs::write(path(state, &id, ".request"), request_bytes).map_err(OpError::io)?;
    write_status(state, &JobStatus::running(&id, &request.op));

    let exe = std::env::current_exe().map_err(OpError::io)?;
    let mut command = std::process::Command::new(exe);
    command
        .arg("--state")
        .arg(state)
        .args(["run", &id])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    {
        use std::os::unix::process::CommandExt;
        // Its own session, so the host closing the exec shell (or WebUI X
        // killing it when the app goes to the background) leaves it running.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    let child = command.spawn().map_err(OpError::io)?;
    let _ = std::fs::write(path(state, &id, ".pid"), child.id().to_string());
    Ok(json!({ "id": id }))
}

fn alive(pid: i32) -> bool {
    // The detached job is our child's session leader, not our child, so it
    // is never a zombie of ours; kill(0) is enough. A zombie of init counts as
    // gone.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => !stat.rsplit(')').next().unwrap_or("").trim_start().starts_with('Z'),
        Err(_) => true,
    }
}

fn poll(state: &Path, id: &str) -> Result<serde_json::Value, OpError> {
    valid_id(id)?;
    let bytes = std::fs::read(path(state, id, ".json"))
        .map_err(|_| OpError::new("not-found", format!("No job {id}")))?;
    let mut status: JobStatus = serde_json::from_slice(&bytes).map_err(OpError::io)?;
    if !status.state.finished() {
        let pid = std::fs::read_to_string(path(state, id, ".pid"))
            .ok()
            .and_then(|s| s.trim().parse::<i32>().ok());
        // Give a fresh job a moment to write its pid file.
        if let Some(pid) = pid {
            if !alive(pid) {
                // It may have finished between our two reads.
                let again = std::fs::read(path(state, id, ".json")).ok();
                if let Some(latest) = again.and_then(|b| serde_json::from_slice::<JobStatus>(&b).ok()) {
                    if latest.state.finished() {
                        return serde_json::to_value(latest).map_err(OpError::io);
                    }
                }
                status.finish(Err(OpError::new("worker-died", "The job's process ended without a result")));
                write_status(state, &status);
            }
        }
    }
    serde_json::to_value(status).map_err(OpError::io)
}

fn cancel(state: &Path, id: &str) -> Result<serde_json::Value, OpError> {
    valid_id(id)?;
    if !path(state, id, ".json").exists() {
        return Err(OpError::new("not-found", format!("No job {id}")));
    }
    std::fs::write(path(state, id, ".cancel"), b"").map_err(OpError::io)?;
    Ok(json!({ "id": id }))
}

struct FileSink {
    state: PathBuf,
    status: Mutex<(JobStatus, Instant)>,
}

impl JobSink for FileSink {
    fn report(&self, progress: Option<f64>, message: Option<&str>) {
        let mut guard = self.status.lock().unwrap();
        guard.0.progress = progress;
        guard.0.message = message.map(str::to_owned);
        // Pollers ask four times a second; writing faster is wasted I/O.
        if guard.1.elapsed() >= Duration::from_millis(100) {
            guard.1 = Instant::now();
            write_status(&self.state, &guard.0);
        }
    }

    fn cancelled(&self) -> bool {
        let id = self.status.lock().unwrap().0.id.clone();
        path(&self.state, &id, ".cancel").exists()
    }
}

fn run_job(handler: &dyn Handler, state: &Path, id: &str) {
    if valid_id(id).is_err() {
        return;
    }
    let request = std::fs::read(path(state, id, ".request"))
        .map_err(OpError::io)
        .and_then(|b| serde_json::from_slice::<Request>(&b).map_err(OpError::io));
    let op = request.as_ref().map(|r| r.op.clone()).unwrap_or_default();
    let sink = std::sync::Arc::new(FileSink {
        state: state.to_owned(),
        status: Mutex::new((JobStatus::running(id, &op), Instant::now())),
    });
    struct Shared(std::sync::Arc<FileSink>);
    impl JobSink for Shared {
        fn report(&self, progress: Option<f64>, message: Option<&str>) {
            self.0.report(progress, message)
        }
        fn cancelled(&self) -> bool {
            self.0.cancelled()
        }
    }
    let result = request.and_then(|r| dispatch(handler, &r, &JobCtx::new(Shared(sink.clone()))));
    let mut status = sink.status.lock().unwrap().0.clone();
    status.finish(result);
    write_status(state, &status);
    let _ = std::fs::remove_file(path(state, id, ".request"));
    let _ = std::fs::remove_file(path(state, id, ".cancel"));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Builtins;
    use serde_json::Value;
    use surfaces_core::text::b64url_encode;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn call_over_command_line() {
        let request = b64url_encode(br#"{"op":"sys.info"}"#);
        let Envelope::Ok(value) = run(&Builtins, &args(&["call", &request])) else { panic!() };
        assert_eq!(value["os"], std::env::consts::OS);
        let Envelope::Error(error) = run(&Builtins, &args(&["call", "!!"])) else { panic!() };
        assert_eq!(error.code, "request");
        let Envelope::Error(error) = run(&Builtins, &args(&["nope"])) else { panic!() };
        assert_eq!(error.code, "usage");
    }

    #[test]
    fn job_files_round_trip_in_process() {
        // `start` re-executes the test binary, so drive `run` directly.
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().to_string_lossy().into_owned();
        let id = "j1-1";
        std::fs::write(
            dir.path().join("j1-1.request"),
            br#"{"op":"sys.wait","input":{"seconds":0.2}}"#,
        )
        .unwrap();
        write_status(dir.path(), &JobStatus::running(id, "sys.wait"));
        run(&Builtins, &args(&["--state", &state, "run", id]));
        let Envelope::Ok(status) = run(&Builtins, &args(&["--state", &state, "poll", id])) else { panic!() };
        assert_eq!(status["state"], "done", "{status}");
        let Envelope::Error(error) = run(&Builtins, &args(&["--state", &state, "poll", "missing"])) else {
            panic!()
        };
        assert_eq!(error.code, "not-found");
        assert!(matches!(run(&Builtins, &args(&["--state", &state, "poll", "../x"])), Envelope::Error(_)));
        let _: Value = status;
    }
}
