use serde::Serialize;
use serde_json::Value;

use crate::{ConvertError, LogEntry};

/// The JSON envelope returned to Dart. One shape for every outcome —
/// success, partial success, or error — so nothing gets dropped.
#[derive(Debug, Clone, Serialize)]
pub struct ConvertEnvelope {
    /// Lottie 5.7 JSON. `null` if conversion failed before the Lottie
    /// stage could produce output.
    pub lottie: Value,

    /// Parsed SVG tree (serialized SvgDocument). `null` if parsing failed
    /// before any document could be built.
    pub svg_raw: Value,

    /// Every log entry captured during this call, in order. Dart replays
    /// these onto the caller-provided `AnimSvgLogger`.
    pub logs: Vec<LogEntry>,

    /// Populated iff the call failed. Partial `lottie`/`svg_raw` may still
    /// be present for diagnostics.
    pub error: Option<ConvertError>,
}
