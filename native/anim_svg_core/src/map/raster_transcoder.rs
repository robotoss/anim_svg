//! Port of `lib/src/data/mappers/raster_transcoder.dart`.
//!
//! Transcodes raster data URIs into formats thorvg can decode.
//!
//! thorvg 1.0's Flutter build ships with loaders `lottie, png, jpg` only —
//! WebP data URIs render as empty pixels. We decode the WebP bytes with
//! `image-webp` (pure-rust) and re-encode as PNG before handing the asset
//! to the Lottie serializer.
//!
//! PNG/JPEG URIs pass through untouched — no decode/encode cost.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use image::{codecs::png::PngEncoder, ImageEncoder, ImageReader};
use std::io::Cursor;

use crate::log::LogCollector;
use crate::parse::data_uri::DataUri;

/// Mirrors `RasterTranscoder.transcodeIfNeeded`. WebP is decoded and
/// re-encoded as PNG; on failure the input is returned unchanged with a
/// warning so the rest of the pipeline still produces a Lottie document.
pub fn transcode_if_needed(uri: DataUri, logs: &mut LogCollector) -> DataUri {
    if uri.mime != "image/webp" {
        return uri;
    }
    match webp_to_png(&uri) {
        Ok(transcoded) => {
            logs.debug(
                "map.raster",
                "webp→png transcoded",
                &[
                    ("src_bytes", uri.base64.len().into()),
                    ("dst_bytes", transcoded.base64.len().into()),
                ],
            );
            transcoded
        }
        Err(reason) => {
            logs.warn(
                "map.raster",
                "webp transcode failed; passing through (will render blank)",
                &[("reason", reason.into())],
            );
            uri
        }
    }
}

fn webp_to_png(uri: &DataUri) -> Result<DataUri, String> {
    let bytes = uri.decode().map_err(|e| e.message)?;
    let img = ImageReader::with_format(Cursor::new(&bytes), image::ImageFormat::WebP)
        .decode()
        .map_err(|e| format!("webp decode: {}", e))?;
    let rgba = img.into_rgba8();
    let (w, h) = rgba.dimensions();
    let mut out = Vec::with_capacity(bytes.len());
    PngEncoder::new(&mut out)
        .write_image(rgba.as_raw(), w, h, image::ExtendedColorType::Rgba8)
        .map_err(|e| format!("png encode: {}", e))?;
    let b64 = STANDARD.encode(&out);
    let raw = format!("data:image/png;base64,{}", b64);
    Ok(DataUri {
        mime: "image/png".to_string(),
        base64: b64,
        raw,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Debug)
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
    fn webp_is_decoded_and_re_encoded_as_png() {
        // Minimal valid WebP (1x1 pixel) generated via `cwebp` for a
        // hot-pink dot — base64 below is small enough to keep inline.
        const WEBP_B64: &str =
            "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA";
        let mut logs = mk_logs();
        let uri = mk_uri("image/webp", WEBP_B64);
        let out = transcode_if_needed(uri, &mut logs);
        assert_eq!(out.mime, "image/png");
        assert!(out.base64.starts_with("iVBORw0KGgo"),
            "expected PNG header in transcoded base64, got {}", &out.base64[..16.min(out.base64.len())]);
        assert!(out.raw.starts_with("data:image/png;base64,"));
        let entries = logs.into_entries();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].stage, "map.raster");
        assert!(entries[0].message.contains("transcoded"));
    }

    #[test]
    fn webp_garbage_falls_back_to_input_with_warning() {
        let mut logs = mk_logs();
        let uri = mk_uri("image/webp", "bm90IGEgcmVhbCB3ZWJw");
        let out = transcode_if_needed(uri.clone(), &mut logs);
        assert_eq!(out.mime, "image/webp");
        assert_eq!(out.base64, uri.base64);
        let entries = logs.into_entries();
        assert_eq!(entries.len(), 1);
        assert!(entries[0].message.contains("transcode failed"));
    }
}
