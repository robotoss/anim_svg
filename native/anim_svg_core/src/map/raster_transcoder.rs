//! Port of `lib/src/data/mappers/raster_transcoder.dart`.
//!
//! Transcodes raster data URIs into formats thorvg can decode.
//!
//! thorvg 1.0's Flutter build ships with loaders `lottie, png, jpg` only —
//! WebP data URIs render as empty pixels. The Dart side decodes WebP bytes
//! and re-encodes them as PNG via `package:image`.
//!
//! **Native stub**: the real WebP → PNG transcode is NOT implemented here
//! because the Rust `image` crate (with WebP + PNG encoders enabled) is
//! heavy enough to bloat the shared library by several MiB. This stub
//! returns the input unchanged and logs a warning so the Dart layer can
//! decide whether to transcode on its side or let the asset render blank.
//! A follow-up PR can wire in a real transcoder.
//!
//! PNG/JPEG URIs pass through untouched (same as Dart).

use crate::log::LogCollector;
use crate::parse::data_uri::DataUri;

/// Mirrors `RasterTranscoder.transcodeIfNeeded`. In the native stub the
/// result is always `Ok(input)`; a warning is emitted when the input is a
/// WebP URI so the caller knows transcoding was skipped.
pub fn transcode_if_needed(uri: DataUri, logs: &mut LogCollector) -> DataUri {
    if uri.mime == "image/webp" {
        logs.warn(
            "map.raster",
            "webp-transcode not yet implemented in native core",
            &[("mime", uri.mime.clone().into())],
        );
    }
    uri
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn mk_uri(mime: &str, b64: &str) -> DataUri {
        DataUri {
            mime: mime.to_string(),
            base64: b64.to_string(),
            raw: format!("data:{};base64,{}", mime, b64),
        }
    }

    #[test]
    fn png_passes_through_unchanged() {
        let mut logs = mk_logs();
        let uri = mk_uri("image/png", "iVBORw0KGgo=");
        let out = transcode_if_needed(uri.clone(), &mut logs);
        assert_eq!(out.mime, "image/png");
        assert_eq!(out.base64, "iVBORw0KGgo=");
        assert_eq!(out.raw, uri.raw);
        assert!(logs.into_entries().is_empty());
    }

    #[test]
    fn jpeg_passes_through_unchanged() {
        let mut logs = mk_logs();
        let uri = mk_uri("image/jpeg", "/9j/4AAQSkZJRg==");
        let out = transcode_if_needed(uri, &mut logs);
        assert_eq!(out.mime, "image/jpeg");
        assert!(logs.into_entries().is_empty());
    }

    #[test]
    fn webp_returns_input_unchanged_and_logs_warning() {
        let mut logs = mk_logs();
        let uri = mk_uri("image/webp", "UklGRh4AAABXRUJQ");
        let out = transcode_if_needed(uri.clone(), &mut logs);
        // Stub: bytes/mime unchanged.
        assert_eq!(out.mime, "image/webp");
        assert_eq!(out.base64, uri.base64);
        let entries = logs.into_entries();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].stage, "map.raster");
        assert!(entries[0].message.contains("webp-transcode"));
    }
}
