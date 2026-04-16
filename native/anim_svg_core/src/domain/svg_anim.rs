//! Port of `lib/src/domain/entities/svg_animation.dart`.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SvgAnimationCalcMode {
    Linear,
    Spline,
    Discrete,
    Paced,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SvgAnimationAdditive {
    Replace,
    Sum,
}

/// SVG/SMIL transform kinds. Mirrors the subset needed to round-trip CSS
/// `transform:` and SMIL `<animateTransform type=...>`. `matrix` is kept for
/// static transforms; the animation side only emits translate/scale/rotate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SvgTransformKind {
    Translate,
    Scale,
    Rotate,
    SkewX,
    SkewY,
    Matrix,
}

/// CSS `animation-direction`. SMIL sources stay `Normal`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SvgAnimationDirection {
    #[default]
    Normal,
    Reverse,
    Alternate,
    AlternateReverse,
}

/// CSS `animation-fill-mode`. SMIL defaults to `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SvgAnimationFillMode {
    #[default]
    None,
    Forwards,
    Backwards,
    Both,
}

/// A single cubic-Bézier easing handle (x1, y1, x2, y2) as parsed from
/// `keySplines` or CSS `cubic-bezier(...)`.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct BezierSpline {
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
}

/// Keyframe timeline for one SVG/CSS animation channel.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgKeyframes {
    pub key_times: Vec<f64>,
    pub values: Vec<String>,
    pub calc_mode: SvgAnimationCalcMode,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub key_splines: Vec<BezierSpline>,
}

/// Common fields for any SMIL/CSS animation node.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgAnimationCommon {
    pub dur_seconds: f64,
    pub repeat_indefinite: bool,
    pub additive: SvgAnimationAdditive,
    pub keyframes: SvgKeyframes,
    #[serde(default)]
    pub delay_seconds: f64,
    #[serde(default)]
    pub direction: SvgAnimationDirection,
    #[serde(default)]
    pub fill_mode: SvgAnimationFillMode,
}

/// Port of `sealed class SvgAnimationNode`. Flat enum with per-variant
/// data is Rust's idiomatic equivalent.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum SvgAnimationNode {
    /// `<animate attributeName="opacity|display|offset-distance|...">`
    Animate {
        attribute_name: String,
        #[serde(flatten)]
        common: SvgAnimationCommon,
    },
    /// `<animateTransform type="translate|scale|rotate|...">`
    AnimateTransform {
        kind: SvgTransformKind,
        #[serde(flatten)]
        common: SvgAnimationCommon,
    },
}

impl SvgAnimationNode {
    pub fn common(&self) -> &SvgAnimationCommon {
        match self {
            SvgAnimationNode::Animate { common, .. } => common,
            SvgAnimationNode::AnimateTransform { common, .. } => common,
        }
    }

    pub fn common_mut(&mut self) -> &mut SvgAnimationCommon {
        match self {
            SvgAnimationNode::Animate { common, .. } => common,
            SvgAnimationNode::AnimateTransform { common, .. } => common,
        }
    }
}
