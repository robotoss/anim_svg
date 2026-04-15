//! Port of `lib/src/data/mappers/image_asset_builder.dart`.
//!
//! Builds a [`LottieAsset`] from an [`SvgImage`]. Validates the data URI and
//! routes it through [`raster_transcoder`] so thorvg (which lacks a WebP
//! loader) can render it. External (non-`data:`) URIs are not supported.

use crate::domain::{LottieAsset, SvgImage};
use crate::error::ConvertError;
use crate::log::LogCollector;
use crate::map::raster_transcoder;
use crate::parse::data_uri;

/// Mirrors `ImageAssetBuilder.build`.
pub fn build(
    image: &SvgImage,
    asset_id: &str,
    logs: &mut LogCollector,
) -> Result<LottieAsset, ConvertError> {
    if !image.href.starts_with("data:") {
        return Err(ConvertError::unsupported_feature(
            "image[external]",
            format!("external image href not supported in MVP: {}", image.href),
        ));
    }
    let parsed = data_uri::parse(&image.href)?;
    let ready = raster_transcoder::transcode_if_needed(parsed, logs);
    Ok(LottieAsset {
        id: asset_id.to_string(),
        width: image.width,
        height: image.height,
        data_uri: ready.as_data_uri().to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::SvgNodeCommon;
    use crate::error::ErrorKind;
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn mk_image(href: &str, w: f64, h: f64) -> SvgImage {
        SvgImage {
            common: SvgNodeCommon::default(),
            href: href.to_string(),
            width: w,
            height: h,
        }
    }

    #[test]
    fn builds_asset_from_png_data_uri() {
        let mut logs = mk_logs();
        let img = mk_image("data:image/png;base64,iVBORw0KGgo=", 32.0, 24.0);
        let out = build(&img, "image_0", &mut logs).unwrap();
        assert_eq!(out.id, "image_0");
        assert_eq!(out.width, 32.0);
        assert_eq!(out.height, 24.0);
        assert_eq!(out.data_uri, "data:image/png;base64,iVBORw0KGgo=");
    }

    #[test]
    fn rejects_external_href() {
        let mut logs = mk_logs();
        let img = mk_image("https://example.com/x.png", 10.0, 10.0);
        let err = build(&img, "image_0", &mut logs).unwrap_err();
        assert_eq!(err.kind, ErrorKind::UnsupportedFeature);
        assert_eq!(err.feature.as_deref(), Some("image[external]"));
    }

    #[test]
    fn webp_passes_through_and_logs_warning() {
        let mut logs = mk_logs();
        let img = mk_image("data:image/webp;base64,UklGRh4AAABXRUJQ", 8.0, 8.0);
        let out = build(&img, "asset_webp", &mut logs).unwrap();
        // Stub: transcoder returns the input unchanged, so the raw URI is preserved.
        assert_eq!(out.data_uri, "data:image/webp;base64,UklGRh4AAABXRUJQ");
        let entries = logs.into_entries();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].stage, "map.raster");
    }

    #[test]
    fn rejects_malformed_data_uri() {
        let mut logs = mk_logs();
        let img = mk_image("data:image/svg+xml,<svg/>", 1.0, 1.0);
        let err = build(&img, "asset", &mut logs).unwrap_err();
        // data_uri::parse rejects non-base64 payloads as UnsupportedFeature.
        assert_eq!(err.kind, ErrorKind::UnsupportedFeature);
    }
}
