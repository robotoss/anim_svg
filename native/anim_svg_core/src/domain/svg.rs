//! Port of `lib/src/domain/entities/svg_document.dart`.

use std::collections::BTreeMap;

use serde::Serialize;

use super::svg_anim::SvgAnimationNode;
use super::svg_motion_path::SvgMotionPath;
use super::svg_transform::SvgStaticTransform;

/// The root parsed document.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgDocument {
    pub width: f64,
    pub height: f64,
    pub view_box: SvgViewBox,
    pub defs: SvgDefs,
    pub root: SvgGroup,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgViewBox {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// Common per-node state shared by every SvgNode variant. Mirrors the
/// Dart `SvgNode` abstract class's fields.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgNodeCommon {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,

    #[serde(default)]
    pub static_transforms: Vec<SvgStaticTransform>,

    #[serde(default)]
    pub animations: Vec<SvgAnimationNode>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter_id: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub mask_id: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub motion_path: Option<SvgMotionPath>,
}

/// Port of `sealed class SvgNode`. Each variant carries a flattened
/// `SvgNodeCommon` plus its own fields.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SvgNode {
    Group(SvgGroup),
    Shape(SvgShape),
    Image(SvgImage),
    Use(SvgUse),
}

impl SvgNode {
    pub fn common(&self) -> &SvgNodeCommon {
        match self {
            SvgNode::Group(g) => &g.common,
            SvgNode::Shape(s) => &s.common,
            SvgNode::Image(i) => &i.common,
            SvgNode::Use(u) => &u.common,
        }
    }

    pub fn common_mut(&mut self) -> &mut SvgNodeCommon {
        match self {
            SvgNode::Group(g) => &mut g.common,
            SvgNode::Shape(s) => &mut s.common,
            SvgNode::Image(i) => &mut i.common,
            SvgNode::Use(u) => &mut u.common,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgGroup {
    #[serde(flatten)]
    pub common: SvgNodeCommon,
    pub children: Vec<SvgNode>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub display_none: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgImage {
    #[serde(flatten)]
    pub common: SvgNodeCommon,
    /// `data:image/...;base64,...` or an external URI.
    pub href: String,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgUse {
    #[serde(flatten)]
    pub common: SvgNodeCommon,
    pub href_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
}

/// Defs table. `BTreeMap` keeps serialization deterministic for parity
/// diffs against Dart (Dart's LinkedHashMap preserves insertion order;
/// we normalize to sorted order in parity tests).
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgDefs {
    pub by_id: BTreeMap<String, SvgNode>,
    #[serde(default)]
    pub gradients: BTreeMap<String, SvgGradient>,
    #[serde(default)]
    pub filters: BTreeMap<String, SvgFilter>,
    #[serde(default)]
    pub masks: BTreeMap<String, SvgMask>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SvgMaskType {
    #[default]
    Luminance,
    Alpha,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SvgMaskUnits {
    UserSpaceOnUse,
    #[default]
    ObjectBoundingBox,
}

/// `<mask>` paint mask. Children are the matte source.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgMask {
    pub id: String,
    pub children: Vec<SvgNode>,
    #[serde(default)]
    pub mask_type: SvgMaskType,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    #[serde(default)]
    pub mask_units: SvgMaskUnits,
    #[serde(default = "SvgMaskUnits::default")]
    pub mask_content_units: SvgMaskUnits,
}

impl Default for SvgMask {
    fn default() -> Self {
        // Match Dart defaults: mask bbox = -10%..110%.
        Self {
            id: String::new(),
            children: Vec::new(),
            mask_type: SvgMaskType::Luminance,
            x: -0.1,
            y: -0.1,
            width: 1.2,
            height: 1.2,
            mask_units: SvgMaskUnits::ObjectBoundingBox,
            mask_content_units: SvgMaskUnits::UserSpaceOnUse,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SvgFilter {
    pub id: String,
    pub primitives: Vec<SvgFilterPrimitive>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SvgColorMatrixKind {
    Saturate,
    Other,
}

/// `<feGaussianBlur>` / `<feColorMatrix>` / `<feComponentTransfer>` — the
/// subset this converter actually maps to Lottie effects. Unsupported
/// primitives are logged (warn) and dropped at parse time.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SvgFilterPrimitive {
    GaussianBlur {
        std_deviation: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        std_deviation_anim: Option<Box<SvgAnimationNode>>,
    },
    ColorMatrix {
        matrix_kind: SvgColorMatrixKind,
        values: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        values_anim: Option<Box<SvgAnimationNode>>,
    },
    ComponentTransfer {
        #[serde(skip_serializing_if = "Option::is_none")]
        slope_r: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        slope_g: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        slope_b: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        slope_r_anim: Option<Box<SvgAnimationNode>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        slope_g_anim: Option<Box<SvgAnimationNode>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        slope_b_anim: Option<Box<SvgAnimationNode>>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SvgGradientKind {
    #[default]
    Linear,
    Radial,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SvgGradientUnits {
    UserSpaceOnUse,
    #[default]
    ObjectBoundingBox,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgGradient {
    pub id: String,
    pub kind: SvgGradientKind,
    pub stops: Vec<SvgStop>,
    #[serde(default)]
    pub units: SvgGradientUnits,
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
    pub cx: f64,
    pub cy: f64,
    pub r: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fx: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fy: Option<f64>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub has_gradient_transform: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gradient_transform: Option<Vec<f64>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgStop {
    pub offset: f64,
    /// Raw CSS-ish colour (`#rrggbb`, `rgb(...)`, named). Parsed later.
    pub color: String,
    #[serde(default = "one_f64")]
    pub stop_opacity: f64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub animations: Vec<SvgAnimationNode>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SvgShapeKind {
    Path,
    Rect,
    Circle,
    Ellipse,
    Line,
    Polyline,
    Polygon,
}

/// Geometric shape node. Geometry fields are stored in raw SVG form; the
/// shape mapper normalizes them to cubic-Bézier contours.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgShape {
    #[serde(flatten)]
    pub common: SvgNodeCommon,
    pub kind: SvgShapeKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub d: Option<String>,
    // rect
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    // circle / ellipse
    pub cx: f64,
    pub cy: f64,
    pub r: f64,
    pub rx: f64,
    pub ry: f64,
    // line
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
    // polyline / polygon — flat `[[x,y], ...]`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub points: Vec<[f64; 2]>,

    pub fill: String,
    pub fill_opacity: f64,
    pub opacity: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stroke: Option<String>,
    pub stroke_width: f64,
    pub stroke_opacity: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stroke_linecap: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stroke_linejoin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stroke_dasharray: Option<String>,
    pub stroke_dashoffset: f64,
}

impl Default for SvgShape {
    fn default() -> Self {
        Self {
            common: SvgNodeCommon::default(),
            kind: SvgShapeKind::Path,
            d: None,
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            cx: 0.0,
            cy: 0.0,
            r: 0.0,
            rx: 0.0,
            ry: 0.0,
            x1: 0.0,
            y1: 0.0,
            x2: 0.0,
            y2: 0.0,
            points: Vec::new(),
            fill: "black".to_string(),
            fill_opacity: 1.0,
            opacity: 1.0,
            stroke: None,
            stroke_width: 0.0,
            stroke_opacity: 1.0,
            stroke_linecap: None,
            stroke_linejoin: None,
            stroke_dasharray: None,
            stroke_dashoffset: 0.0,
        }
    }
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[allow(dead_code)]
fn one_f64() -> f64 {
    1.0
}
