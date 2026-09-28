//! Host-neutral pieces every surfaces app shares.
//!
//! - [`protocol`]: the ops request, response and job status documents that
//!   travel between Dart and Rust, whichever transport carries them (the
//!   worker over `ksu.exec` on WebUI, flutter_rust_bridge in-process on AERA
//!   and desktop).
//! - [`text`]: shell quoting and the naming rules WebUI hosts use.
//! - [`hash`]: SHA-256 helpers.
//! - [`abi`]: one JSON call shape for an app's core, over flutter_rust_bridge
//!   on native targets and plain wasm exports on the web.
//!
//! Everything here is pure and builds for `wasm32-unknown-unknown` too, so an
//! app's core crate can use it on every target.

pub mod abi;
pub mod hash;
pub mod protocol;
pub mod text;

pub use protocol::{Envelope, JobState, JobStatus, OpError, Request};
