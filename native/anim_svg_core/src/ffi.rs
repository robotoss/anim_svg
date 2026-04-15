//! C ABI. Keep this file free of domain logic — it only marshals.
//!
//! Contract:
//! - `anim_svg_convert` returns a heap-allocated UTF-8 NUL-terminated JSON
//!   envelope. Caller must free it with `anim_svg_free_string`.
//! - All `extern "C"` entry points catch panics and fold them into the
//!   envelope so the host process never crashes.

use std::ffi::{c_char, CStr, CString};
use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use crate::{convert, ConvertEnvelope, ConvertError, ConvertOptions, LogEntry, LogLevel, VERSION};

/// Per-call options. `log_level` is a NUL-terminated ASCII string; null
/// means "info". `reserved` is 0-filled for future expansion.
#[repr(C)]
pub struct AnimSvgConvertOptions {
    pub log_level: *const c_char,
    pub reserved: u32,
}

/// Convert an SVG string to a Lottie JSON envelope.
///
/// # Safety
/// `svg` must be a valid NUL-terminated UTF-8 C string. `opts` may be
/// null or point to a valid `AnimSvgConvertOptions`. Returned pointer
/// must be freed with `anim_svg_free_string`. Returns null only on
/// allocation failure or if `svg` is null.
#[no_mangle]
pub unsafe extern "C" fn anim_svg_convert(
    svg: *const c_char,
    opts: *const AnimSvgConvertOptions,
) -> *const c_char {
    if svg.is_null() {
        return ptr::null();
    }

    let result = panic::catch_unwind(AssertUnwindSafe(|| {
        let svg_str = match CStr::from_ptr(svg).to_str() {
            Ok(s) => s,
            Err(err) => {
                return envelope_for_error(ConvertError::parse_with_source(
                    "svg input is not valid UTF-8",
                    err.to_string(),
                ));
            }
        };

        let options = build_options(opts);
        convert(svg_str, options)
    }));

    let envelope = match result {
        Ok(env) => env,
        Err(panic_payload) => {
            let msg = panic_message(&panic_payload);
            envelope_for_error(ConvertError::conversion(format!(
                "native panic during conversion: {msg}"
            )))
        }
    };

    serialize_envelope(&envelope)
}

/// Free a string returned by any `anim_svg_*` function.
///
/// # Safety
/// `s` must have been returned by an `anim_svg_*` function and not
/// previously freed. Passing null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn anim_svg_free_string(s: *const c_char) {
    if s.is_null() {
        return;
    }
    // Retake ownership so it's dropped.
    drop(CString::from_raw(s as *mut c_char));
}

/// Returns the native core version as a static C string. Do not free.
#[no_mangle]
pub extern "C" fn anim_svg_core_version() -> *const c_char {
    // VERSION is a &'static str at compile time; append NUL.
    // We lazily construct once into a static to avoid a new alloc per call.
    static mut CACHED: *const c_char = ptr::null();
    static ONCE: std::sync::Once = std::sync::Once::new();
    unsafe {
        ONCE.call_once(|| {
            let c = CString::new(VERSION).expect("VERSION must not contain NUL");
            CACHED = c.into_raw();
        });
        CACHED
    }
}

// -------- helpers --------

unsafe fn build_options(opts: *const AnimSvgConvertOptions) -> ConvertOptions {
    if opts.is_null() {
        return ConvertOptions::default();
    }
    let o = &*opts;
    let log_level = if o.log_level.is_null() {
        LogLevel::default()
    } else {
        CStr::from_ptr(o.log_level)
            .to_str()
            .ok()
            .and_then(LogLevel::from_str)
            .unwrap_or_default()
    };
    ConvertOptions { log_level }
}

fn envelope_for_error(err: ConvertError) -> ConvertEnvelope {
    ConvertEnvelope {
        lottie: serde_json::Value::Null,
        svg_raw: serde_json::Value::Null,
        logs: Vec::<LogEntry>::new(),
        error: Some(err),
    }
}

fn serialize_envelope(envelope: &ConvertEnvelope) -> *const c_char {
    let json = match serde_json::to_string(envelope) {
        Ok(s) => s,
        Err(err) => {
            // Last-ditch: hand-build a minimal error envelope as text.
            format!(
                r#"{{"lottie":null,"svg_raw":null,"logs":[],"error":{{"kind":"conversion","message":"envelope serialization failed: {}"}}}}"#,
                err.to_string().replace('"', "'")
            )
        }
    };

    match CString::new(json) {
        Ok(c) => c.into_raw() as *const c_char,
        Err(_) => ptr::null(),
    }
}

fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_string()
    }
}
