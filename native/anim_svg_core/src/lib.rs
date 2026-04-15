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

    let doc = match parse::xml::parse(svg, &mut logs) {
        Ok(d) => d,
        Err(error) => {
            return ConvertEnvelope {
                lottie: serde_json::Value::Null,
                svg_raw: serde_json::Value::Null,
                logs: logs.into_entries(),
                error: Some(error),
            };
        }
    };

    let svg_raw = serde_json::to_value(&doc).unwrap_or(serde_json::Value::Null);

    let lottie_doc = map::svg_to_lottie::map(doc, options.frame_rate, &mut logs);
    let lottie = serialize::lottie::serialize(&lottie_doc);

    logs.info(
        "convert",
        "done",
        &[
            ("layers", (lottie_doc.layers.len() as u64).into()),
            ("assets", (lottie_doc.assets.len() as u64).into()),
        ],
    );

    ConvertEnvelope {
        lottie,
        svg_raw,
        logs: logs.into_entries(),
        error: None,
    }
}

/// Options for a single conversion call.
#[derive(Debug, Clone)]
pub struct ConvertOptions {
    pub log_level: LogLevel,
    pub frame_rate: f64,
}

impl Default for ConvertOptions {
    fn default() -> Self {
        Self {
            log_level: LogLevel::default(),
            frame_rate: 60.0,
        }
    }
}
