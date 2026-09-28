//! The ops wire format. Dart's `Ops` client in `package:surfaces` reads and
//! writes exactly these documents.
//!
//! ```json
//! {"op": "fs.stat", "input": {"path": "/data/adb"}}          // Request
//! {"ok": {...}}  or  {"error": {"code": "...", "message": "..."}}   // Envelope
//! {"id": "j1", "state": "running", "progress": 0.4, "message": "..."} // JobStatus
//! ```

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Largest request a transport accepts, in bytes of JSON. Requests carry
/// paths and parameters, never bulk data.
pub const REQUEST_LIMIT: usize = 128 * 1024;

/// One operation to run: its name and its input.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub op: String,
    #[serde(default)]
    pub input: Value,
}

impl Request {
    pub fn new(op: impl Into<String>, input: Value) -> Self {
        Self { op: op.into(), input }
    }

    /// Parses a request, enforcing [`REQUEST_LIMIT`].
    pub fn from_json(json: &str) -> Result<Self, OpError> {
        if json.len() > REQUEST_LIMIT {
            return Err(OpError::new("request", "Request exceeds 128 KiB"));
        }
        serde_json::from_str(json).map_err(|e| OpError::new("request", e.to_string()))
    }
}

/// Why an operation failed. `code` is stable and machine-readable
/// (`unavailable`, `not-found`, `cancelled`, `request`, `io`...); `message`
/// is for people.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OpError {
    pub code: String,
    pub message: String,
}

impl OpError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into() }
    }

    /// The operation is not offered on this target.
    pub fn unavailable(op: &str) -> Self {
        Self::new("unavailable", format!("{op} is not available here"))
    }

    pub fn io(error: impl std::fmt::Display) -> Self {
        Self::new("io", error.to_string())
    }
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for OpError {}

/// The answer to a call: a value or an error, never both.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Envelope {
    Ok(Value),
    Error(OpError),
}

impl Envelope {
    pub fn from_result(result: Result<Value, OpError>) -> Self {
        match result {
            Ok(value) => Envelope::Ok(value),
            Err(error) => Envelope::Error(error),
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("an envelope always serialises")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JobState {
    Running,
    Done,
    Failed,
    Cancelled,
}

impl JobState {
    pub fn finished(self) -> bool {
        !matches!(self, JobState::Running)
    }
}

/// Where a long operation stands.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JobStatus {
    pub id: String,
    pub op: String,
    pub state: JobState,
    /// 0 to 1 when the job knows how far it is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<OpError>,
}

impl JobStatus {
    pub fn running(id: &str, op: &str) -> Self {
        Self {
            id: id.into(),
            op: op.into(),
            state: JobState::Running,
            progress: None,
            message: None,
            result: None,
            error: None,
        }
    }

    /// Records how the job ended.
    pub fn finish(&mut self, result: Result<Value, OpError>) {
        match result {
            Ok(value) => {
                self.state = JobState::Done;
                self.progress = Some(1.0);
                self.result = Some(value);
            }
            Err(error) if error.code == "cancelled" => {
                self.state = JobState::Cancelled;
                self.error = Some(error);
            }
            Err(error) => {
                self.state = JobState::Failed;
                self.error = Some(error);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn envelope_shapes() {
        assert_eq!(Envelope::Ok(json!(1)).to_json(), r#"{"ok":1}"#);
        assert_eq!(
            Envelope::Error(OpError::new("x", "y")).to_json(),
            r#"{"error":{"code":"x","message":"y"}}"#
        );
    }

    #[test]
    fn request_defaults_input() {
        let request = Request::from_json(r#"{"op":"sys.info"}"#).unwrap();
        assert_eq!(request, Request::new("sys.info", Value::Null));
    }

    #[test]
    fn job_finish_maps_cancel() {
        let mut status = JobStatus::running("a", "b");
        status.finish(Err(OpError::new("cancelled", "stop")));
        assert_eq!(status.state, JobState::Cancelled);
        let text = serde_json::to_string(&status).unwrap();
        assert!(text.contains(r#""state":"cancelled""#), "{text}");
    }
}
