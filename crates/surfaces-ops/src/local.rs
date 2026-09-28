//! Runs ops in the app's own process: the transport on AERA and desktop,
//! where the app's flutter_rust_bridge crate calls straight into Rust.
//!
//! Every method takes and returns JSON strings in the [`surfaces_core::protocol`]
//! shapes, so the app's bridge crate only needs four `#[frb(sync)]`
//! functions that forward here:
//!
//! ```ignore
//! static OPS: LazyLock<Runner> = LazyLock::new(|| Runner::new(MyHandler));
//! #[frb(sync)] pub fn ops_call(request: String) -> String { OPS.call(&request) }
//! #[frb(sync)] pub fn ops_start(request: String) -> String { OPS.start(&request) }
//! #[frb(sync)] pub fn ops_poll(id: String) -> String { OPS.poll(&id) }
//! #[frb(sync)] pub fn ops_cancel(id: String) -> String { OPS.cancel(&id) }
//! ```
//!
//! Jobs run on their own thread. On wasm there are no threads, so `start`
//! runs the job to the end before it returns; `poll` then reports it done.

use crate::{dispatch, Envelope, Handler, JobCtx, JobSink, JobStatus, OpError, Request};
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

struct LocalJob {
    status: Mutex<JobStatus>,
    cancel: AtomicBool,
}

impl JobSink for Arc<LocalJob> {
    fn report(&self, progress: Option<f64>, message: Option<&str>) {
        let mut status = self.status.lock().unwrap();
        status.progress = progress;
        status.message = message.map(str::to_owned);
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }
}

/// Runs a [`Handler`]'s ops in-process. Keeps finished jobs until they are
/// polled once after finishing, or until 64 newer jobs push them out.
pub struct Runner {
    handler: Arc<dyn Handler>,
    jobs: Mutex<HashMap<String, Arc<LocalJob>>>,
    order: Mutex<Vec<String>>,
    next: AtomicU64,
}

impl Runner {
    pub fn new(handler: impl Handler) -> Self {
        Self {
            handler: Arc::new(handler),
            jobs: Mutex::new(HashMap::new()),
            order: Mutex::new(Vec::new()),
            next: AtomicU64::new(1),
        }
    }

    /// Runs one call to the end. `request` is a Request document; the
    /// answer is an Envelope document.
    pub fn call(&self, request: &str) -> String {
        Envelope::from_result(
            Request::from_json(request).and_then(|r| dispatch(self.handler.as_ref(), &r, &JobCtx::none())),
        )
        .to_json()
    }

    /// Starts a job and answers `{"ok": {"id": ...}}` at once.
    pub fn start(&self, request: &str) -> String {
        let request = match Request::from_json(request) {
            Ok(request) => request,
            Err(error) => return Envelope::Error(error).to_json(),
        };
        let id = format!("local-{}", self.next.fetch_add(1, Ordering::Relaxed));
        let job = Arc::new(LocalJob {
            status: Mutex::new(JobStatus::running(&id, &request.op)),
            cancel: AtomicBool::new(false),
        });
        {
            let mut order = self.order.lock().unwrap();
            let mut jobs = self.jobs.lock().unwrap();
            order.push(id.clone());
            while order.len() > 64 {
                let old = order.remove(0);
                jobs.remove(&old);
            }
            jobs.insert(id.clone(), job.clone());
        }
        let handler = self.handler.clone();
        let run = move || {
            let result = dispatch(handler.as_ref(), &request, &JobCtx::new(job.clone()));
            job.status.lock().unwrap().finish(result);
        };
        #[cfg(not(target_family = "wasm"))]
        std::thread::spawn(run);
        #[cfg(target_family = "wasm")]
        run();
        Envelope::Ok(json!({ "id": id })).to_json()
    }

    /// Answers `{"ok": JobStatus}`.
    pub fn poll(&self, id: &str) -> String {
        let job = self.jobs.lock().unwrap().get(id).cloned();
        Envelope::from_result(match job {
            Some(job) => {
                let status = job.status.lock().unwrap().clone();
                Ok(serde_json::to_value(status).expect("a status always serialises"))
            }
            None => Err(OpError::new("not-found", format!("No job {id}"))),
        })
        .to_json()
    }

    /// Asks a job to stop. It stops at its next [`JobCtx::check`].
    pub fn cancel(&self, id: &str) -> String {
        let job = self.jobs.lock().unwrap().get(id).cloned();
        Envelope::from_result(match job {
            Some(job) => {
                job.cancel.store(true, Ordering::Relaxed);
                Ok(json!({ "id": id }))
            }
            None => Err(OpError::new("not-found", format!("No job {id}"))),
        })
        .to_json()
    }
}

#[cfg(all(test, not(target_family = "wasm")))]
mod tests {
    use super::*;
    use crate::Builtins;
    use serde_json::Value;

    fn ok(text: &str) -> Value {
        let value: Value = serde_json::from_str(text).unwrap();
        value.get("ok").cloned().unwrap_or_else(|| panic!("{text}"))
    }

    #[test]
    fn call_and_job() {
        let runner = Runner::new(Builtins);
        assert_eq!(ok(&runner.call(r#"{"op":"sys.info"}"#))["os"], std::env::consts::OS);
        let bad: Value = serde_json::from_str(&runner.call("{")).unwrap();
        assert_eq!(bad["error"]["code"], "request");

        let id = ok(&runner.start(r#"{"op":"sys.wait","input":{"seconds":0.3}}"#))["id"]
            .as_str()
            .unwrap()
            .to_owned();
        loop {
            let status = ok(&runner.poll(&id));
            if status["state"] != "running" {
                assert_eq!(status["state"], "done");
                assert_eq!(status["result"]["waited"], 0.3);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[test]
    fn cancel_stops_job() {
        let runner = Runner::new(Builtins);
        let id = ok(&runner.start(r#"{"op":"sys.wait","input":{"seconds":30}}"#))["id"]
            .as_str()
            .unwrap()
            .to_owned();
        ok(&runner.cancel(&id));
        for _ in 0..50 {
            let status = ok(&runner.poll(&id));
            if status["state"] == "cancelled" {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        panic!("job did not stop");
    }
}
