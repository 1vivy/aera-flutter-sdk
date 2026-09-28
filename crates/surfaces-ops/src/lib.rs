//! Privileged or long work for surfaces apps.
//!
//! An app defines its operations once, as a [`Handler`] that takes a
//! [`Request`] (an op name and a JSON input) and returns JSON. The same
//! handler then runs on every target; only the transport changes:
//!
//! | Target | Transport | Here |
//! | --- | --- | --- |
//! | WebUI (KernelSU, WebUI X...) | the app's worker binary, run as root over `ksu.exec` | [`worker::main`] |
//! | AERA, desktop | in-process, through the app's flutter_rust_bridge crate | [`local::Runner`] |
//! | Plain browser (wasm) | in-process, jobs run inline | [`local::Runner`] |
//!
//! Long operations become jobs: `start` returns an id at once, `poll` reports
//! progress, `cancel` asks the job to stop. A handler reports progress and
//! notices cancellation through its [`JobCtx`], and does not care which
//! transport runs it.
//!
//! Rules from Canoe Boot Manager's WebUI worker carry over: requests carry
//! paths, never bulk bytes; requests stay under 128 KiB and results under
//! 1 MiB.

pub mod builtin;
pub mod local;
#[cfg(unix)]
pub mod worker;

use serde_json::Value;
pub use surfaces_core::protocol::{Envelope, JobState, JobStatus, OpError, Request};

/// Largest result a job or call may return, in bytes of JSON.
pub const RESULT_LIMIT: usize = 1024 * 1024;

/// Runs an app's operations.
pub trait Handler: Send + Sync + 'static {
    /// Runs `request`. Long work reports through `job` and returns
    /// `Err(OpError { code: "cancelled", .. })` (see [`JobCtx::check`]) when
    /// asked to stop. Unknown ops should fall through to
    /// [`builtin::call`], which answers `unknown-op` for anything it does not
    /// know either.
    fn call(&self, request: &Request, job: &JobCtx) -> Result<Value, OpError>;
}

impl<F> Handler for F
where
    F: Fn(&Request, &JobCtx) -> Result<Value, OpError> + Send + Sync + 'static,
{
    fn call(&self, request: &Request, job: &JobCtx) -> Result<Value, OpError> {
        self(request, job)
    }
}

/// Only the built-in ops.
pub struct Builtins;

impl Handler for Builtins {
    fn call(&self, request: &Request, job: &JobCtx) -> Result<Value, OpError> {
        builtin::call(request, job)
    }
}

/// Where a running job reports to.
pub trait JobSink: Send + Sync {
    fn report(&self, progress: Option<f64>, message: Option<&str>);
    fn cancelled(&self) -> bool;
}

/// A handler's view of the job it runs in. For a plain call there is no job,
/// and reporting does nothing.
pub struct JobCtx {
    sink: Option<Box<dyn JobSink>>,
}

impl JobCtx {
    /// No job: progress goes nowhere and nothing cancels.
    pub fn none() -> Self {
        Self { sink: None }
    }

    pub fn new(sink: impl JobSink + 'static) -> Self {
        Self { sink: Some(Box::new(sink)) }
    }

    /// Whether this call runs as a job someone can watch.
    pub fn is_job(&self) -> bool {
        self.sink.is_some()
    }

    /// Reports how far the job is (0 to 1) and what it is doing.
    pub fn progress(&self, fraction: f64, message: impl AsRef<str>) {
        if let Some(sink) = &self.sink {
            sink.report(Some(fraction.clamp(0.0, 1.0)), Some(message.as_ref()));
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.sink.as_ref().is_some_and(|sink| sink.cancelled())
    }

    /// `Err(cancelled)` once someone asked the job to stop; use with `?` in
    /// loops.
    pub fn check(&self) -> Result<(), OpError> {
        if self.is_cancelled() {
            Err(OpError::new("cancelled", "Cancelled"))
        } else {
            Ok(())
        }
    }
}

/// Runs one call and wraps the answer, enforcing [`RESULT_LIMIT`].
pub fn dispatch(handler: &dyn Handler, request: &Request, job: &JobCtx) -> Result<Value, OpError> {
    let value = handler.call(request, job)?;
    let size = serde_json::to_vec(&value).map(|v| v.len()).unwrap_or(usize::MAX);
    if size > RESULT_LIMIT {
        return Err(OpError::new("result-too-large", "Result exceeds 1 MiB; return a path instead"));
    }
    Ok(value)
}

/// Reads a typed input, with a readable error.
pub fn input<T: serde::de::DeserializeOwned>(request: &Request) -> Result<T, OpError> {
    serde_json::from_value(request.input.clone())
        .map_err(|e| OpError::new("input", format!("{}: {e}", request.op)))
}
