//! Port of `lib/src/data/parsers/data_uri_decoder.dart`.
//!
//! Only base64 data URIs are supported. Percent-encoded and plain-text
//! data URIs return `UnsupportedFeature` so the caller can route them
//! through a different path or drop them with a warning.

use base64::{engine::general_purpose::STANDARD, Engine as _};

use crate::error::ConvertError;

#[derive(Debug, Clone)]
pub struct DataUri {
    pub mime: String,
    pub base64: String,
    pub raw: String,
}

impl DataUri {
    pub fn decode(&self) -> Result<Vec<u8>, ConvertError> {
        STANDARD.decode(self.base64.as_bytes()).map_err(|e| {
            ConvertError::parse(format!("data URI base64 decode failed: {}", e))
        })
    }

    pub fn as_data_uri(&self) -> &str {
        &self.raw
    }
}

pub fn parse(href: &str) -> Result<DataUri, ConvertError> {
    if !href.starts_with("data:") {
        return Err(ConvertError::parse(format!(
            "not a data URI: {}",
            preview(href)
        )));
    }
    let comma = match href.find(',') {
        Some(i) => i,
        None => {
            return Err(ConvertError::parse(format!(
                "data URI missing comma: {}",
                preview(href)
            )));
        }
    };
    let meta = &href[5..comma];
    let payload = &href[comma + 1..];
    if !meta.ends_with(";base64") {
        return Err(ConvertError::unsupported_feature(
            "data-uri[non-base64]",
            "only base64 data URIs are supported",
        ));
    }
    let mime = &meta[..meta.len() - ";base64".len()];
    Ok(DataUri {
        mime: mime.to_string(),
        base64: payload.to_string(),
        raw: href.to_string(),
    })
}

fn preview(href: &str) -> String {
    if href.len() > 40 {
        format!("{}...", &href[..40])
    } else {
        href.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_base64_png() {
        let uri = "data:image/png;base64,iVBORw0KGgo=";
        let out = parse(uri).unwrap();
        assert_eq!(out.mime, "image/png");
        assert_eq!(out.base64, "iVBORw0KGgo=");
        assert_eq!(out.raw, uri);
    }

    #[test]
    fn decodes_base64_bytes() {
        let uri = "data:image/png;base64,iVBORw0KGgo=";
        let out = parse(uri).unwrap();
        let bytes = out.decode().unwrap();
        assert_eq!(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }

    #[test]
    fn rejects_non_data_uri() {
        let err = parse("https://example.com/x.png").unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::Parse);
    }

    #[test]
    fn rejects_non_base64_data_uri() {
        let err = parse("data:image/svg+xml,<svg/>").unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::UnsupportedFeature);
    }

    #[test]
    fn rejects_data_uri_without_comma() {
        let err = parse("data:image/png;base64").unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::Parse);
    }
}
