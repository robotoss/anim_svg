//! Port of `lib/src/domain/entities/lottie_animation.dart`.
//!
//! Internal in-memory representation. The serializer in `serialize::lottie`
//! translates this into the wire Lottie 5.7 schema (`ks`, `ty`, `ip`, ...).

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieDoc {
    pub version: String,
    pub frame_rate: f64,
    pub in_point: f64,
    pub out_point: f64,
    pub width: f64,
    pub height: f64,
    pub assets: Vec<LottieAsset>,
    pub layers: Vec<LottieLayer>,
}

impl LottieDoc {
    pub const DEFAULT_VERSION: &'static str = "5.7.0";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LottieShapeKind {
    Rect,
    Ellipse,
    Path,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LottieShapeItem {
    Geometry(LottieShapeGeometry),
    Fill(LottieShapeFill),
    Stroke(LottieShapeStroke),
    TrimPath(LottieShapeTrimPath),
    GradientFill(LottieShapeGradientFill),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapeGeometry {
    pub kind: LottieShapeKind,

    // `sh` — path
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub vertices: Vec<[f64; 2]>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub in_tangents: Vec<[f64; 2]>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub out_tangents: Vec<[f64; 2]>,
    #[serde(default = "true_bool")]
    pub closed: bool,

    // `rc` — rect
    #[serde(default)]
    pub rect_position: [f64; 2],
    #[serde(default)]
    pub rect_size: [f64; 2],
    #[serde(default)]
    pub rect_roundness: f64,

    // `el` — ellipse
    #[serde(default)]
    pub ellipse_position: [f64; 2],
    #[serde(default)]
    pub ellipse_size: [f64; 2],

    /// Non-None when the path animates (`<animate attributeName="d">`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_keyframes: Option<Vec<LottieShapePathKeyframe>>,
}

impl Default for LottieShapeGeometry {
    fn default() -> Self {
        Self {
            kind: LottieShapeKind::Path,
            vertices: Vec::new(),
            in_tangents: Vec::new(),
            out_tangents: Vec::new(),
            closed: true,
            rect_position: [0.0, 0.0],
            rect_size: [0.0, 0.0],
            rect_roundness: 0.0,
            ellipse_position: [0.0, 0.0],
            ellipse_size: [0.0, 0.0],
            path_keyframes: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapePathKeyframe {
    pub time: f64,
    pub vertices: Vec<[f64; 2]>,
    pub in_tangents: Vec<[f64; 2]>,
    pub out_tangents: Vec<[f64; 2]>,
    pub closed: bool,
    #[serde(default)]
    pub hold: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bezier_in: Option<BezierHandle>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bezier_out: Option<BezierHandle>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapeFill {
    /// Normalised RGBA in [0, 1]. Length 4.
    pub color: [f64; 4],
    #[serde(default = "hundred_f64")]
    pub opacity: f64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapeStroke {
    pub color: [f64; 4],
    pub opacity: f64,
    pub width: f64,
    /// `1`=butt, `2`=round, `3`=square (Lottie `lc`).
    pub line_cap: i32,
    /// `1`=miter, `2`=round, `3`=bevel (Lottie `lj`).
    pub line_join: i32,
    pub miter_limit: f64,
}

impl Default for LottieShapeStroke {
    fn default() -> Self {
        Self {
            color: [0.0, 0.0, 0.0, 1.0],
            opacity: 100.0,
            width: 1.0,
            line_cap: 1,
            line_join: 1,
            miter_limit: 4.0,
        }
    }
}

/// Lottie Trim Paths modifier (`ty:"tm"`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapeTrimPath {
    pub start: LottieScalarProp,
    pub end: LottieScalarProp,
    pub offset: LottieScalarProp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LottieGradientKind {
    Linear,
    Radial,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapeGradientFill {
    pub kind: LottieGradientKind,
    pub color_stop_count: usize,
    pub start_point: [f64; 2],
    pub end_point: [f64; 2],
    pub stops: LottieGradientStops,
    #[serde(default = "hundred_f64")]
    pub opacity: f64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LottieGradientStops {
    Static { values: Vec<f64> },
    Animated { keyframes: Vec<LottieGradientKeyframe> },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieGradientKeyframe {
    pub time: f64,
    pub values: Vec<f64>,
    #[serde(default)]
    pub hold: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieAsset {
    pub id: String,
    pub width: f64,
    pub height: f64,
    /// Embedded `data:image/...;base64,...` URI (Lottie `p` with `e:1`).
    pub data_uri: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieLayerCommon {
    pub index: i32,
    pub name: String,
    pub transform: LottieTransform,
    pub in_point: f64,
    pub out_point: f64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub effects: Vec<LottieEffect>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub td: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tt: Option<i32>,
}

/// Port of the sealed `LottieLayer` hierarchy.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LottieLayer {
    Image(LottieImageLayer),
    Shape(LottieShapeLayer),
    Null(LottieNullLayer),
}

impl LottieLayer {
    pub fn common(&self) -> &LottieLayerCommon {
        match self {
            LottieLayer::Image(l) => &l.common,
            LottieLayer::Shape(l) => &l.common,
            LottieLayer::Null(l) => &l.common,
        }
    }

    pub fn common_mut(&mut self) -> &mut LottieLayerCommon {
        match self {
            LottieLayer::Image(l) => &mut l.common,
            LottieLayer::Shape(l) => &mut l.common,
            LottieLayer::Null(l) => &mut l.common,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieImageLayer {
    #[serde(flatten)]
    pub common: LottieLayerCommon,
    pub ref_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieShapeLayer {
    #[serde(flatten)]
    pub common: LottieLayerCommon,
    pub shapes: Vec<LottieShapeItem>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieNullLayer {
    #[serde(flatten)]
    pub common: LottieLayerCommon,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LottieEffect {
    Blur { blurriness: LottieScalarProp },
    Brightness { brightness: LottieScalarProp },
    HueSaturation { master_saturation: LottieScalarProp },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieTransform {
    pub anchor: LottieVectorProp,
    pub position: LottieVectorProp,
    pub scale: LottieVectorProp,
    pub rotation: LottieScalarProp,
    pub opacity: LottieScalarProp,
}

impl Default for LottieTransform {
    fn default() -> Self {
        Self {
            anchor: LottieVectorProp::Static { value: vec![0.0, 0.0] },
            position: LottieVectorProp::Static { value: vec![0.0, 0.0] },
            scale: LottieVectorProp::Static { value: vec![100.0, 100.0] },
            rotation: LottieScalarProp::Static { value: 0.0 },
            opacity: LottieScalarProp::Static { value: 100.0 },
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LottieVectorProp {
    Static { value: Vec<f64> },
    Animated { keyframes: Vec<LottieVectorKeyframe> },
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LottieScalarProp {
    Static { value: f64 },
    Animated { keyframes: Vec<LottieScalarKeyframe> },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieVectorKeyframe {
    /// In frames.
    pub time: f64,
    pub start: Vec<f64>,
    #[serde(default)]
    pub hold: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bezier_in: Option<BezierHandle>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bezier_out: Option<BezierHandle>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieScalarKeyframe {
    pub time: f64,
    pub start: f64,
    #[serde(default)]
    pub hold: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bezier_in: Option<BezierHandle>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bezier_out: Option<BezierHandle>,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct BezierHandle {
    pub x: f64,
    pub y: f64,
}

// Reserved for future Deserialize impls — harmless dead code today.
#[allow(dead_code)]
fn hundred_f64() -> f64 {
    100.0
}

#[allow(dead_code)]
fn true_bool() -> bool {
    true
}
