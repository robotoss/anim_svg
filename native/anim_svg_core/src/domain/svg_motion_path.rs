//! Port of `lib/src/domain/entities/svg_motion_path.dart`.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SvgMotionRotateKind {
    Auto,
    Reverse,
    Fixed,
}

/// CSS `offset-rotate`. `Fixed(deg)` keeps the node upright at a constant
/// angle; `Auto` / `Reverse` follow the path tangent.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgMotionRotate {
    pub kind: SvgMotionRotateKind,
    #[serde(default)]
    pub angle_deg: f64,
}

impl SvgMotionRotate {
    pub const AUTO: Self = Self {
        kind: SvgMotionRotateKind::Auto,
        angle_deg: 0.0,
    };
    pub const REVERSE: Self = Self {
        kind: SvgMotionRotateKind::Reverse,
        angle_deg: 0.0,
    };
    pub const fn fixed(angle_deg: f64) -> Self {
        Self {
            kind: SvgMotionRotateKind::Fixed,
            angle_deg,
        }
    }
}

impl Default for SvgMotionRotate {
    fn default() -> Self {
        Self::AUTO
    }
}

/// CSS Motion Path (`offset-path: path('...')` + `offset-rotate: ...`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgMotionPath {
    pub path_data: String,
    #[serde(default)]
    pub rotate: SvgMotionRotate,
}
