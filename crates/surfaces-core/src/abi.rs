//! The core ABI: how Dart calls an app's Rust core on every target with one
//! shape, JSON requests in and JSON (or raw bytes) out.
//!
//! On native targets (AERA, desktop) the app's flutter_rust_bridge crate
//! forwards two `#[frb(sync)]` functions to [`call_json`] and [`call_bytes`].
//! On the web (WebUI hosts and plain browsers) the same crate is built for
//! `wasm32-unknown-unknown` and [`export_wasm_core!`] exports them as plain
//! wasm functions, which `package:surfaces_webui` loads with
//! `WebAssembly.instantiate`. That needs no wasm-bindgen, no threads and no
//! shared memory, so it runs on hosts that cannot send COOP/COEP headers
//! (all WebUI hosts), where flutter_rust_bridge's web mode cannot start: its
//! web build links shared memory, which needs cross-origin isolation.
//!
//! Core calls are synchronous and run on the UI thread, so keep them to
//! fast work: parsing, validation, planning, small computations. Anything
//! slow or privileged belongs in ops.

use crate::protocol::{Envelope, OpError, Request};
use serde_json::Value;

/// Runs `core` on a Request document and returns an Envelope document.
pub fn call_json(request: &str, core: impl FnOnce(&Request) -> Result<Value, OpError>) -> String {
    Envelope::from_result(Request::from_json(request).and_then(|r| core(&r))).to_json()
}

/// Runs `core` for a binary answer. The first byte says what follows:
/// `0` the bytes, `1` an Envelope document with the error.
pub fn call_bytes(request: &str, core: impl FnOnce(&Request) -> Result<Vec<u8>, OpError>) -> Vec<u8> {
    match Request::from_json(request).and_then(|r| core(&r)) {
        Ok(mut bytes) => {
            bytes.insert(0, 0);
            bytes
        }
        Err(error) => {
            let mut out = vec![1];
            out.extend_from_slice(Envelope::Error(error).to_json().as_bytes());
            out
        }
    }
}

#[doc(hidden)]
pub fn leak(bytes: Vec<u8>) -> u64 {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len() as u64;
    let ptr = Box::into_raw(boxed) as *mut u8 as usize as u64;
    (ptr << 32) | len
}

/// # Safety
/// `ptr` must point at `len` readable bytes.
#[doc(hidden)]
pub unsafe fn read(ptr: *const u8, len: usize) -> String {
    String::from_utf8_lossy(std::slice::from_raw_parts(ptr, len)).into_owned()
}

/// Exports an app's core as wasm functions:
///
/// - `surfaces_alloc(len) -> ptr` and `surfaces_free(ptr, len)`
/// - `surfaces_call(ptr, len) -> u64` (JSON Envelope)
/// - `surfaces_bytes(ptr, len) -> u64` (status byte + bytes, see [`call_bytes`])
///
/// A returned `u64` packs the result as `ptr << 32 | len`; the caller copies
/// it out and frees it with `surfaces_free`.
///
/// ```ignore
/// #[cfg(target_family = "wasm")]
/// surfaces_core::export_wasm_core!(crate::core::call, crate::core::bytes);
/// ```
#[macro_export]
macro_rules! export_wasm_core {
    ($call:path, $bytes:path) => {
        #[no_mangle]
        pub extern "C" fn surfaces_alloc(len: usize) -> *mut u8 {
            let mut buffer = ::std::vec::Vec::<u8>::with_capacity(len);
            let ptr = buffer.as_mut_ptr();
            ::std::mem::forget(buffer);
            ptr
        }

        /// # Safety
        /// `ptr` and `len` must come from `surfaces_alloc` or a returned result.
        #[no_mangle]
        pub unsafe extern "C" fn surfaces_free(ptr: *mut u8, len: usize) {
            drop(::std::vec::Vec::from_raw_parts(ptr, len, len));
        }

        /// # Safety
        /// `ptr` must point at `len` bytes of UTF-8 JSON.
        #[no_mangle]
        pub unsafe extern "C" fn surfaces_call(ptr: *const u8, len: usize) -> u64 {
            let request = $crate::abi::read(ptr, len);
            $crate::abi::leak($crate::abi::call_json(&request, $call).into_bytes())
        }

        /// # Safety
        /// `ptr` must point at `len` bytes of UTF-8 JSON.
        #[no_mangle]
        pub unsafe extern "C" fn surfaces_bytes(ptr: *const u8, len: usize) -> u64 {
            let request = $crate::abi::read(ptr, len);
            $crate::abi::leak($crate::abi::call_bytes(&request, $bytes))
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn json_and_bytes() {
        let answer = call_json(r#"{"op":"x","input":2}"#, |r| Ok(json!(r.input.as_i64().unwrap() * 2)));
        assert_eq!(answer, r#"{"ok":4}"#);
        assert_eq!(call_bytes(r#"{"op":"x"}"#, |_| Ok(vec![7, 8])), vec![0, 7, 8]);
        let error = call_bytes("{", |_| Ok(vec![]));
        assert_eq!(error[0], 1);
    }
}
