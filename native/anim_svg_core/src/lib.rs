//! anim_svg_core — native SVG → Lottie converter.
//!
//! Phase 1: stub. The FFI surface is in place but `convert` returns a
//! fixed envelope with an `unsupported_feature` error. Real pipeline
//! lands in later phases.

pub mod domain;
pub mod envelope;
pub mod error;
pub mod ffi;
pub mod log;
pub mod map;
pub mod parse;
pub mod serialize;

pub use envelope::ConvertEnvelope;
pub use error::{ConvertError, ErrorKind};
pub use log::{LogCollector, LogEntry, LogLevel};

/// Crate semver exposed to FFI callers for compatibility checks.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Pure-Rust conversion entry point. FFI wraps this.
///
/// Always returns a `ConvertEnvelope` — errors live inside it so callers
/// get the partial logs and any raw data produced before failure.
pub fn convert(svg: &str, options: ConvertOptions) -> ConvertEnvelope {
    let mut logs = LogCollector::new(options.log_level);
    logs.info("convert", "start", &[("svg_bytes", svg.len().into())]);

    // Phase 1 stub: no pipeline yet.
    let error = ConvertError::unsupported_feature(
        "converter_pipeline",
        "native pipeline not yet implemented (phase 1 scaffold)",
    );
    logs.warn(
        "convert",
        "native pipeline not yet implemented",
        &[("phase", "1".into())],
    );

    ConvertEnvelope {
        lottie: serde_json::Value::Null,
        svg_raw: serde_json::Value::Null,
        logs: logs.into_entries(),
        error: Some(error),
    }
}

/// Options for a single conversion call.
#[derive(Debug, Clone, Default)]
pub struct ConvertOptions {
    pub log_level: LogLevel,
}
