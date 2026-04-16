use serde::Serialize;

/// Kind of conversion error. Mirrors the Dart exception hierarchy:
/// ParseException, UnsupportedFeatureException, ConversionException.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Parse,
    UnsupportedFeature,
    Conversion,
}

/// Structured conversion error. Never raised as a Rust panic across the
/// FFI boundary — always embedded in the envelope so partial logs survive.
#[derive(Debug, Clone, Serialize)]
pub struct ConvertError {
    pub kind: ErrorKind,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub feature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl ConvertError {
    pub fn parse(message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Parse,
            message: message.into(),
            source: None,
            feature: None,
            reason: None,
        }
    }

    pub fn parse_with_source(message: impl Into<String>, source: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Parse,
            message: message.into(),
            source: Some(source.into()),
            feature: None,
            reason: None,
        }
    }

    pub fn unsupported_feature(feature: impl Into<String>, reason: impl Into<String>) -> Self {
        let feature = feature.into();
        let reason = reason.into();
        Self {
            kind: ErrorKind::UnsupportedFeature,
            message: format!("unsupported: {feature}: {reason}"),
            source: None,
            feature: Some(feature),
            reason: Some(reason),
        }
    }

    pub fn conversion(message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Conversion,
            message: message.into(),
            source: None,
            feature: None,
            reason: None,
        }
    }
}

impl std::fmt::Display for ConvertError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for ConvertError {}
