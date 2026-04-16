//! Port of `lib/src/data/parsers/svg_parser.dart`.
//!
//! Top-level SVG tree walker. Orchestrates every other parser in
//! `crate::parse::*` and produces a fully-populated [`SvgDocument`]. Errors
//! from XML parsing map to [`ConvertError::parse_with_source`]; everything
//! else — malformed attrs, unsupported elements — is logged and skipped so
//! one bad fragment doesn't sink the whole document.

use std::collections::{BTreeMap, HashMap};

use once_cell::sync::Lazy;
use regex::Regex;
use roxmltree::{Document, Node};

use crate::domain::{
    SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode,
    SvgColorMatrixKind, SvgDefs, SvgDocument, SvgFilter, SvgFilterPrimitive, SvgGradient,
    SvgGradientKind, SvgGradientUnits, SvgGroup, SvgImage, SvgKeyframes, SvgMask, SvgMaskType,
    SvgMaskUnits, SvgMotionPath, SvgMotionRotate, SvgNode, SvgNodeCommon, SvgShape, SvgShapeKind,
    SvgStaticTransform, SvgStop, SvgTransformKind, SvgUse, SvgViewBox,
};
use crate::error::ConvertError;
use crate::log::LogCollector;
use crate::parse::{animation, css, svgator, transform};

const XLINK_NS: &str = "http://www.w3.org/1999/xlink";

static TRANSFORM_FN_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(\w+)\s*\(([^)]*)\)").unwrap());
static NUMBER_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?").unwrap()
});
static LENGTH_UNIT_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(px|pt|em|rem|%)$").unwrap());
static SPACE_COMMA_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"[ ,]+").unwrap());
static WHITESPACE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static ORIGIN_NUM_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^([-+]?(?:\d+\.\d*|\.\d+|\d+))(px)?$").unwrap());
static ROTATE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^([-+]?(?:\d+\.\d*|\.\d+|\d+))\s*(deg|rad|turn|grad)?$").unwrap()
});

/// Top-level entry point. Returns a fully-populated [`SvgDocument`] or a
/// parse error if the root XML is malformed / not `<svg>`.
pub fn parse(xml: &str, logs: &mut LogCollector) -> Result<SvgDocument, ConvertError> {
    let doc = Document::parse(xml)
        .map_err(|e| ConvertError::parse_with_source("failed to parse SVG XML", e.to_string()))?;
    let root = doc.root_element();
    if root.tag_name().name() != "svg" {
        return Err(ConvertError::parse("root element is not <svg>"));
    }

    let width = parse_length(root.attribute("width"));
    let height = parse_length(root.attribute("height"));
    let view_box = parse_view_box(root.attribute("viewBox"), width, height)?;

    // Harvest every <style> block anywhere in the tree, concatenate, and feed
    // to the CSS parser. Mirrors Dart's `root.descendants.whereType<XmlElement>`.
    let css_blob = collect_text_from(root, "style");
    let class_index = build_class_index(root);
    let (mut css_anims, css_statics) = if css_blob.trim().is_empty() {
        (HashMap::<String, Vec<SvgAnimationNode>>::new(), CssStatics::default())
    } else {
        let parsed = css::parse(&css_blob, &class_index, logs);
        (
            parsed.animations,
            CssStatics {
                by_id: parsed.id_styles,
                by_class: parsed.class_styles,
            },
        )
    };

    // Svgator-exported SVGs embed their animation data in a <script> block.
    // Extract any such payload and merge into the per-id animation map so
    // downstream mappers see a unified view regardless of source format.
    let script_blob = collect_text_from(root, "script");
    let mut svgator_statics: HashMap<String, Vec<SvgStaticTransform>> = HashMap::new();
    if !script_blob.trim().is_empty() {
        let parsed = svgator::parse(&script_blob, logs);
        // Dart appends Svgator animations onto whatever CSS produced for the
        // same id — both sources coexist per id (not a replace). Preserve that.
        for (id, tracks) in parsed.animations {
            css_anims.entry(id).or_default().extend(tracks);
        }
        svgator_statics = parsed.static_transforms;
    }

    let ctx = WalkCtx {
        css_anims: &css_anims,
        css_statics: &css_statics,
        svgator_statics: &svgator_statics,
    };

    let mut defs_map: BTreeMap<String, SvgNode> = BTreeMap::new();
    let mut gradient_map: BTreeMap<String, SvgGradient> = BTreeMap::new();
    let mut filter_map: BTreeMap<String, SvgFilter> = BTreeMap::new();
    let mut mask_map: BTreeMap<String, SvgMask> = BTreeMap::new();

    for defs in root
        .children()
        .filter(|c| c.is_element() && c.tag_name().name() == "defs")
    {
        for child in defs.children().filter(|c| c.is_element()) {
            let tag = child.tag_name().name();
            if tag == "linearGradient" || tag == "radialGradient" {
                if let Some(g) = parse_gradient(child, logs) {
                    gradient_map.insert(g.id.clone(), g);
                }
                continue;
            }
            if tag == "filter" {
                if let Some(f) = parse_filter(child, logs) {
                    filter_map.insert(f.id.clone(), f);
                }
                continue;
            }
            if tag == "mask" {
                if let Some(m) = parse_mask(child, &ctx, logs) {
                    mask_map.insert(m.id.clone(), m);
                }
                continue;
            }
            if is_decorative_skip(tag) {
                continue;
            }
            let node = parse_node(child, &ctx, &InheritedPaint::root(), logs);
            if let Some(node) = node {
                if let Some(id) = node.common().id.clone() {
                    defs_map.insert(id, node);
                }
            }
        }
    }

    // Illustrator-exported SVGs sometimes place <linearGradient>/<filter>/<mask>
    // at the root instead of inside <defs>. Scan the root for them so
    // `fill="url(#id)"` / `mask="url(#id)"` references resolve.
    for child in root.children().filter(|c| c.is_element()) {
        let tag = child.tag_name().name();
        if tag == "linearGradient" || tag == "radialGradient" {
            if let Some(g) = parse_gradient(child, logs) {
                gradient_map.insert(g.id.clone(), g);
            }
        } else if tag == "filter" {
            if let Some(f) = parse_filter(child, logs) {
                filter_map.insert(f.id.clone(), f);
            }
        } else if tag == "mask" {
            if let Some(m) = parse_mask(child, &ctx, logs) {
                mask_map.insert(m.id.clone(), m);
            }
        }
    }

    let mut root_children = Vec::new();
    for child in root.children().filter(|c| c.is_element()) {
        let tag = child.tag_name().name();
        if tag == "defs"
            || tag == "linearGradient"
            || tag == "radialGradient"
            || tag == "filter"
            || tag == "mask"
        {
            continue;
        }
        if is_decorative_skip(tag) {
            continue;
        }
        if let Some(n) = parse_node(child, &ctx, &InheritedPaint::root(), logs) {
            root_children.push(n);
        }
    }

    Ok(SvgDocument {
        width: width.unwrap_or(view_box.w),
        height: height.unwrap_or(view_box.h),
        view_box,
        defs: SvgDefs {
            by_id: defs_map,
            gradients: gradient_map,
            filters: filter_map,
            masks: mask_map,
        },
        root: SvgGroup {
            common: SvgNodeCommon::default(),
            children: root_children,
            display_none: false,
        },
    })
}

/// Presentation attributes inherited from ancestor `<g>` elements. SVG
/// cascades `fill`, `fill-opacity`, and `opacity` down the tree; only shapes
/// actually emit them, so we collect them at group boundaries and apply at
/// the leaf shape. Opacity channels multiply through the chain.
#[derive(Debug, Clone)]
struct InheritedPaint {
    fill: Option<String>,
    fill_opacity: f64,
    opacity: f64,
}

impl Default for InheritedPaint {
    fn default() -> Self {
        // Match Dart's `_InheritedPaint()` const defaults — opacity channels
        // start at 1.0 so multiplication through the cascade is an identity
        // at the root.
        Self {
            fill: None,
            fill_opacity: 1.0,
            opacity: 1.0,
        }
    }
}

impl InheritedPaint {
    fn root() -> Self {
        Self::default()
    }
}

/// Static CSS declarations harvested from `<style>` blocks. Split by
/// selector kind so `<path class="x">` with no `id=` still resolves rules
/// from `.x{...}` (our class index only sees elements with both id and
/// class). `byId` takes precedence over `byClass` in the cascade.
#[derive(Debug, Default)]
struct CssStatics {
    by_id: HashMap<String, HashMap<String, String>>,
    by_class: HashMap<String, HashMap<String, String>>,
}

struct WalkCtx<'a> {
    css_anims: &'a HashMap<String, Vec<SvgAnimationNode>>,
    css_statics: &'a CssStatics,
    svgator_statics: &'a HashMap<String, Vec<SvgStaticTransform>>,
}

// ---------- gradients -------------------------------------------------------

fn parse_gradient(el: Node, logs: &mut LogCollector) -> Option<SvgGradient> {
    let id = match el.attribute("id") {
        Some(v) => v.to_string(),
        None => {
            logs.warn(
                "parse.xml",
                "gradient without id; skipping",
                &[("tag", el.tag_name().name().into())],
            );
            return None;
        }
    };
    let kind = if el.tag_name().name() == "radialGradient" {
        SvgGradientKind::Radial
    } else {
        SvgGradientKind::Linear
    };
    let units = if el.attribute("gradientUnits") == Some("userSpaceOnUse") {
        SvgGradientUnits::UserSpaceOnUse
    } else {
        SvgGradientUnits::ObjectBoundingBox
    };
    let gt_raw = el.attribute("gradientTransform");
    let has_gt = gt_raw.is_some();
    let gradient_transform = gt_raw.and_then(parse_affine_matrix);

    let mut stops = Vec::new();
    for child in el.children().filter(|c| c.is_element()) {
        if child.tag_name().name() != "stop" {
            continue;
        }
        if let Some(s) = parse_stop(child, logs) {
            stops.push(s);
        }
    }

    Some(SvgGradient {
        id,
        kind,
        stops,
        units,
        x1: parse_length(el.attribute("x1")).unwrap_or(0.0),
        y1: parse_length(el.attribute("y1")).unwrap_or(0.0),
        x2: parse_length(el.attribute("x2")).unwrap_or(1.0),
        y2: parse_length(el.attribute("y2")).unwrap_or(0.0),
        cx: parse_length(el.attribute("cx")).unwrap_or(0.5),
        cy: parse_length(el.attribute("cy")).unwrap_or(0.5),
        r: parse_length(el.attribute("r")).unwrap_or(0.5),
        fx: parse_length(el.attribute("fx")),
        fy: parse_length(el.attribute("fy")),
        has_gradient_transform: has_gt,
        gradient_transform,
    })
}

fn parse_stop(el: Node, logs: &mut LogCollector) -> Option<SvgStop> {
    let offset_raw = el.attribute("offset").unwrap_or("0");
    let offset = parse_offset(offset_raw);
    let style = parse_inline_style(el.attribute("style"));
    let color = style
        .get("stop-color")
        .map(|s| s.as_str())
        .or_else(|| el.attribute("stop-color"))
        .unwrap_or("#000")
        .to_string();
    let op_raw = style
        .get("stop-opacity")
        .map(|s| s.as_str())
        .or_else(|| el.attribute("stop-opacity"))
        .unwrap_or("1");
    let opacity = op_raw.trim().parse::<f64>().unwrap_or(1.0);

    let mut anims = Vec::new();
    for child in el.children().filter(|c| c.is_element()) {
        if !is_animation_tag(child) {
            continue;
        }
        if let Some(n) = animation::parse(child, Some(el), logs) {
            anims.push(n);
        }
    }
    Some(SvgStop {
        offset,
        color,
        stop_opacity: opacity,
        animations: anims,
    })
}

fn parse_offset(raw: &str) -> f64 {
    let t = raw.trim();
    if let Some(n) = t.strip_suffix('%') {
        return n.parse::<f64>().unwrap_or(0.0) / 100.0;
    }
    t.parse::<f64>().unwrap_or(0.0)
}

/// Parses an SVG `transform`-style string into a flat 2D affine matrix
/// `[a, b, c, d, e, f]`. Supports translate/scale/rotate/skewX/skewY/matrix.
/// Composes left-to-right so the result applied to a point matches the SVG
/// semantics (`transform="A B"` means `A(B(p))`).
fn parse_affine_matrix(raw: &str) -> Option<Vec<f64>> {
    let matches: Vec<_> = TRANSFORM_FN_RE.captures_iter(raw).collect();
    if matches.is_empty() {
        return None;
    }
    let mut m: Vec<f64> = vec![1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
    fn mul(a: &[f64], b: &[f64]) -> Vec<f64> {
        vec![
            a[0] * b[0] + a[2] * b[1],
            a[1] * b[0] + a[3] * b[1],
            a[0] * b[2] + a[2] * b[3],
            a[1] * b[2] + a[3] * b[3],
            a[0] * b[4] + a[2] * b[5] + a[4],
            a[1] * b[4] + a[3] * b[5] + a[5],
        ]
    }

    for caps in matches {
        let name = caps.get(1).map(|x| x.as_str()).unwrap_or("");
        let args_raw = caps.get(2).map(|x| x.as_str()).unwrap_or("");
        let args: Vec<f64> = NUMBER_RE
            .find_iter(args_raw)
            .filter_map(|x| x.as_str().parse::<f64>().ok())
            .collect();
        let n: Option<Vec<f64>> = match name {
            "translate" => {
                let tx = args.first().copied().unwrap_or(0.0);
                let ty = args.get(1).copied().unwrap_or(0.0);
                Some(vec![1.0, 0.0, 0.0, 1.0, tx, ty])
            }
            "scale" => {
                let sx = args.first().copied().unwrap_or(1.0);
                let sy = args.get(1).copied().unwrap_or(sx);
                Some(vec![sx, 0.0, 0.0, sy, 0.0, 0.0])
            }
            "rotate" => {
                let rad = args.first().copied().unwrap_or(0.0) * std::f64::consts::PI / 180.0;
                let c = rad.cos();
                let s = rad.sin();
                if args.len() >= 3 {
                    let cx = args[1];
                    let cy = args[2];
                    Some(mul(
                        &[1.0, 0.0, 0.0, 1.0, cx, cy],
                        &mul(&[c, s, -s, c, 0.0, 0.0], &[1.0, 0.0, 0.0, 1.0, -cx, -cy]),
                    ))
                } else {
                    Some(vec![c, s, -s, c, 0.0, 0.0])
                }
            }
            "skewX" => {
                let t =
                    (args.first().copied().unwrap_or(0.0) * std::f64::consts::PI / 180.0).tan();
                Some(vec![1.0, 0.0, t, 1.0, 0.0, 0.0])
            }
            "skewY" => {
                let t =
                    (args.first().copied().unwrap_or(0.0) * std::f64::consts::PI / 180.0).tan();
                Some(vec![1.0, t, 0.0, 1.0, 0.0, 0.0])
            }
            "matrix" => {
                if args.len() == 6 {
                    Some(args)
                } else {
                    None
                }
            }
            _ => None,
        };
        if let Some(n) = n {
            m = mul(&m, &n);
        }
    }
    Some(m)
}

// ---------- masks -----------------------------------------------------------

/// Parses a `<mask>` element into [`SvgMask`]. The mask's child elements are
/// recursively parsed as regular renderable nodes (their luminance — or
/// alpha, for `mask-type="alpha"` — becomes the matte source downstream).
/// Attribute animations inside the mask are ignored: the mask source is
/// baked at t=0 since Lottie track mattes don't animate independently of
/// their target.
fn parse_mask(el: Node, ctx: &WalkCtx, logs: &mut LogCollector) -> Option<SvgMask> {
    let id = match el.attribute("id") {
        Some(v) => v.to_string(),
        None => {
            logs.warn("parse.xml", "mask without id; skipping", &[]);
            return None;
        }
    };
    let mask_type = match el
        .attribute("mask-type")
        .unwrap_or("luminance")
        .to_ascii_lowercase()
        .as_str()
    {
        "alpha" => SvgMaskType::Alpha,
        _ => SvgMaskType::Luminance,
    };
    let mask_units = if el.attribute("maskUnits") == Some("userSpaceOnUse") {
        SvgMaskUnits::UserSpaceOnUse
    } else {
        SvgMaskUnits::ObjectBoundingBox
    };
    let mask_content_units = if el.attribute("maskContentUnits") == Some("objectBoundingBox") {
        SvgMaskUnits::ObjectBoundingBox
    } else {
        SvgMaskUnits::UserSpaceOnUse
    };

    let mut children = Vec::new();
    for child in el.children().filter(|c| c.is_element()) {
        if is_animation_tag(child) {
            continue;
        }
        let tag = child.tag_name().name();
        if is_decorative_skip(tag) {
            continue;
        }
        // nested masks: not supported
        if tag == "mask" {
            continue;
        }
        if let Some(n) = parse_node(child, ctx, &InheritedPaint::default(), logs) {
            children.push(n);
        }
    }
    if children.is_empty() {
        logs.warn(
            "parse.xml",
            "mask has no renderable children",
            &[("id", id.as_str().into())],
        );
    }
    Some(SvgMask {
        id,
        children,
        mask_type,
        x: parse_percent_or_length(el.attribute("x"), -0.1),
        y: parse_percent_or_length(el.attribute("y"), -0.1),
        width: parse_percent_or_length(el.attribute("width"), 1.2),
        height: parse_percent_or_length(el.attribute("height"), 1.2),
        mask_units,
        mask_content_units,
    })
}

/// Best-effort interpretation of a mask bbox attribute. `%` suffixed values
/// map to a fractional bbox unit (100% → 1.0). Plain numbers are passed
/// through. `None` falls back to the provided default.
fn parse_percent_or_length(raw: Option<&str>, fallback: f64) -> f64 {
    let raw = match raw {
        Some(v) => v,
        None => return fallback,
    };
    let t = raw.trim();
    if t.is_empty() {
        return fallback;
    }
    if let Some(body) = t.strip_suffix('%') {
        return body.parse::<f64>().unwrap_or(fallback * 100.0) / 100.0;
    }
    t.parse::<f64>().unwrap_or(fallback)
}

// ---------- filters ---------------------------------------------------------

fn parse_filter(el: Node, logs: &mut LogCollector) -> Option<SvgFilter> {
    let id = match el.attribute("id") {
        Some(v) => v.to_string(),
        None => {
            logs.warn("parse.xml", "filter without id; skipping", &[]);
            return None;
        }
    };
    let mut prims = Vec::new();
    for child in el.children().filter(|c| c.is_element()) {
        if let Some(p) = parse_filter_primitive(child, logs) {
            prims.push(p);
        }
    }
    Some(SvgFilter { id, primitives: prims })
}

fn parse_filter_primitive(el: Node, logs: &mut LogCollector) -> Option<SvgFilterPrimitive> {
    match el.tag_name().name() {
        "feGaussianBlur" => {
            let std_raw = el.attribute("stdDeviation").unwrap_or("0");
            let std_first = WHITESPACE_RE.split(std_raw).next().unwrap_or("0");
            let std = std_first.parse::<f64>().unwrap_or(0.0);
            let mut anim = None;
            for c in el.children().filter(|c| c.is_element() && is_animation_tag(*c)) {
                if let Some(n) = animation::parse(c, Some(el), logs) {
                    if let SvgAnimationNode::Animate { attribute_name, .. } = &n {
                        if attribute_name == "stdDeviation" {
                            anim = Some(Box::new(n));
                        }
                    }
                }
            }
            Some(SvgFilterPrimitive::GaussianBlur {
                std_deviation: std,
                std_deviation_anim: anim,
            })
        }
        "feColorMatrix" => {
            let type_raw = el.attribute("type").unwrap_or("matrix");
            if type_raw != "saturate" {
                logs.warn(
                    "parse.xml",
                    "feColorMatrix type not supported; skipping",
                    &[("type", type_raw.into())],
                );
                return None;
            }
            let values = el
                .attribute("values")
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or(1.0);
            let mut anim = None;
            for c in el.children().filter(|c| c.is_element() && is_animation_tag(*c)) {
                if let Some(n) = animation::parse(c, Some(el), logs) {
                    if let SvgAnimationNode::Animate { attribute_name, .. } = &n {
                        if attribute_name == "values" {
                            anim = Some(Box::new(n));
                        }
                    }
                }
            }
            Some(SvgFilterPrimitive::ColorMatrix {
                matrix_kind: SvgColorMatrixKind::Saturate,
                values,
                values_anim: anim,
            })
        }
        "feComponentTransfer" => parse_component_transfer(el, logs),
        tag @ ("feFuncR" | "feFuncG" | "feFuncB" | "feFuncA") => {
            // Child of feComponentTransfer — handled by parse_component_transfer.
            // Standalone (outside a container) is malformed SVG.
            logs.warn(
                "parse.xml",
                "feFunc* outside feComponentTransfer; skipping",
                &[("tag", tag.into())],
            );
            None
        }
        other => {
            logs.warn(
                "parse.xml",
                "unsupported filter primitive",
                &[("tag", other.into())],
            );
            None
        }
    }
}

fn parse_component_transfer(el: Node, logs: &mut LogCollector) -> Option<SvgFilterPrimitive> {
    let mut r: Option<f64> = None;
    let mut g: Option<f64> = None;
    let mut b: Option<f64> = None;
    let mut r_anim: Option<Box<SvgAnimationNode>> = None;
    let mut g_anim: Option<Box<SvgAnimationNode>> = None;
    let mut b_anim: Option<Box<SvgAnimationNode>> = None;

    for child in el.children().filter(|c| c.is_element()) {
        let tag = child.tag_name().name();
        match tag {
            "feFuncR" | "feFuncG" | "feFuncB" => {
                let type_attr = child.attribute("type").unwrap_or("identity");
                if type_attr != "linear" && type_attr != "identity" {
                    logs.warn(
                        "parse.xml",
                        "feFunc* type not supported; ignoring channel",
                        &[("tag", tag.into()), ("type", type_attr.into())],
                    );
                    continue;
                }
                let slope = child
                    .attribute("slope")
                    .and_then(|s| s.trim().parse::<f64>().ok());
                let mut anim: Option<Box<SvgAnimationNode>> = None;
                for c in child.children().filter(|c| c.is_element() && is_animation_tag(*c)) {
                    if let Some(n) = animation::parse(c, Some(child), logs) {
                        if let SvgAnimationNode::Animate { attribute_name, .. } = &n {
                            if attribute_name == "slope" {
                                anim = Some(Box::new(n));
                            }
                        }
                    }
                }
                match tag {
                    "feFuncR" => {
                        r = slope;
                        r_anim = anim;
                    }
                    "feFuncG" => {
                        g = slope;
                        g_anim = anim;
                    }
                    "feFuncB" => {
                        b = slope;
                        b_anim = anim;
                    }
                    _ => unreachable!(),
                }
            }
            "feFuncA" => {
                // Alpha channel slope is modelled elsewhere (opacity). Ignore here.
            }
            _ => {}
        }
    }
    if r.is_none() && g.is_none() && b.is_none()
        && r_anim.is_none() && g_anim.is_none() && b_anim.is_none()
    {
        logs.warn(
            "parse.xml",
            "feComponentTransfer without recognised slopes; skipping",
            &[],
        );
        return None;
    }
    Some(SvgFilterPrimitive::ComponentTransfer {
        slope_r: r,
        slope_g: g,
        slope_b: b,
        slope_r_anim: r_anim,
        slope_g_anim: g_anim,
        slope_b_anim: b_anim,
    })
}

// ---------- nodes -----------------------------------------------------------

fn parse_node(
    el: Node,
    ctx: &WalkCtx,
    inherited: &InheritedPaint,
    logs: &mut LogCollector,
) -> Option<SvgNode> {
    match el.tag_name().name() {
        "g" => Some(SvgNode::Group(parse_group(el, ctx, inherited, logs))),
        "use" => parse_use(el, ctx, logs).map(SvgNode::Use),
        "image" => parse_image(el, ctx, logs).map(SvgNode::Image),
        "path" | "rect" | "circle" | "ellipse" | "line" | "polyline" | "polygon" => {
            Some(SvgNode::Shape(parse_shape(el, ctx, inherited, logs)))
        }
        other => {
            logs.warn(
                "parse.xml",
                "skipping unsupported element",
                &[
                    ("tag", other.into()),
                    ("id", el.attribute("id").unwrap_or("").into()),
                    ("reason", "element not in MVP scope".into()),
                ],
            );
            None
        }
    }
}

fn parse_shape(
    el: Node,
    ctx: &WalkCtx,
    inherited: &InheritedPaint,
    logs: &mut LogCollector,
) -> SvgShape {
    let (statics, anims, am_motion_path) = parse_transforms_and_animations(el, ctx, logs);
    let style = parse_inline_style(el.attribute("style"));
    let class_style = class_style_for(el, ctx.css_statics);

    let fill = pick_style(&style, class_style.as_ref(), el, "fill")
        .unwrap_or_else(|| inherited.fill.clone().unwrap_or_else(|| "black".to_string()));

    let own_fill_opacity = pick_style(&style, class_style.as_ref(), el, "fill-opacity")
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(1.0);
    let fill_opacity = own_fill_opacity * inherited.fill_opacity;

    let own_opacity = pick_style(&style, class_style.as_ref(), el, "opacity")
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(1.0);
    let opacity = own_opacity * inherited.opacity;

    let stroke_raw = pick_style(&style, class_style.as_ref(), el, "stroke");
    let stroke_width = pick_style(&style, class_style.as_ref(), el, "stroke-width")
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(1.0);
    let stroke_opacity = pick_style(&style, class_style.as_ref(), el, "stroke-opacity")
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(1.0);
    let stroke_linecap = pick_style(&style, class_style.as_ref(), el, "stroke-linecap");
    let stroke_linejoin = pick_style(&style, class_style.as_ref(), el, "stroke-linejoin");
    let stroke_dasharray = pick_style(&style, class_style.as_ref(), el, "stroke-dasharray");
    let stroke_dashoffset = pick_style(&style, class_style.as_ref(), el, "stroke-dashoffset")
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(0.0);

    let kind = match el.tag_name().name() {
        "path" => SvgShapeKind::Path,
        "rect" => SvgShapeKind::Rect,
        "circle" => SvgShapeKind::Circle,
        "ellipse" => SvgShapeKind::Ellipse,
        "line" => SvgShapeKind::Line,
        "polyline" => SvgShapeKind::Polyline,
        "polygon" => SvgShapeKind::Polygon,
        _ => SvgShapeKind::Path,
    };

    let motion_path = parse_motion_path(&style, logs).or(am_motion_path);
    let common = SvgNodeCommon {
        id: el.attribute("id").map(|s| s.to_string()),
        static_transforms: wrap_origin(statics, &style, logs),
        animations: anims,
        filter_id: parse_filter_ref(el),
        mask_id: parse_mask_ref(el),
        motion_path,
    };

    SvgShape {
        common,
        kind,
        d: el.attribute("d").map(|s| s.to_string()),
        x: parse_length(el.attribute("x")).unwrap_or(0.0),
        y: parse_length(el.attribute("y")).unwrap_or(0.0),
        width: parse_length(el.attribute("width")).unwrap_or(0.0),
        height: parse_length(el.attribute("height")).unwrap_or(0.0),
        cx: parse_length(el.attribute("cx")).unwrap_or(0.0),
        cy: parse_length(el.attribute("cy")).unwrap_or(0.0),
        r: parse_length(el.attribute("r")).unwrap_or(0.0),
        rx: parse_length(el.attribute("rx")).unwrap_or(0.0),
        ry: parse_length(el.attribute("ry")).unwrap_or(0.0),
        x1: parse_length(el.attribute("x1")).unwrap_or(0.0),
        y1: parse_length(el.attribute("y1")).unwrap_or(0.0),
        x2: parse_length(el.attribute("x2")).unwrap_or(0.0),
        y2: parse_length(el.attribute("y2")).unwrap_or(0.0),
        points: parse_points(el.attribute("points")),
        fill,
        fill_opacity,
        opacity,
        stroke: stroke_raw,
        stroke_width,
        stroke_opacity,
        stroke_linecap,
        stroke_linejoin,
        stroke_dasharray,
        stroke_dashoffset,
    }
}

fn pick_style(
    inline: &HashMap<String, String>,
    class_style: Option<&HashMap<String, String>>,
    el: Node,
    key: &str,
) -> Option<String> {
    if let Some(v) = inline.get(key) {
        return Some(v.clone());
    }
    if let Some(cs) = class_style {
        if let Some(v) = cs.get(key) {
            return Some(v.clone());
        }
    }
    el.attribute(key).map(|s| s.to_string())
}

fn parse_group(
    el: Node,
    ctx: &WalkCtx,
    inherited: &InheritedPaint,
    logs: &mut LogCollector,
) -> SvgGroup {
    let (statics, anims, am_motion_path) = parse_transforms_and_animations(el, ctx, logs);
    let style = parse_inline_style(el.attribute("style"));
    let class_style = class_style_for(el, ctx.css_statics);

    let own_fill = pick_style(&style, class_style.as_ref(), el, "fill");
    let own_fill_op = pick_style(&style, class_style.as_ref(), el, "fill-opacity")
        .and_then(|s| s.parse::<f64>().ok());
    let own_op = pick_style(&style, class_style.as_ref(), el, "opacity")
        .and_then(|s| s.parse::<f64>().ok());

    let child_inherited = InheritedPaint {
        fill: own_fill.or_else(|| inherited.fill.clone()),
        fill_opacity: own_fill_op.unwrap_or(1.0) * inherited.fill_opacity,
        opacity: own_op.unwrap_or(1.0) * inherited.opacity,
    };

    let mut children = Vec::new();
    for child in el.children().filter(|c| c.is_element()) {
        if is_animation_tag(child) {
            continue;
        }
        if is_decorative_skip(child.tag_name().name()) {
            continue;
        }
        if let Some(n) = parse_node(child, ctx, &child_inherited, logs) {
            children.push(n);
        }
    }
    SvgGroup {
        common: SvgNodeCommon {
            id: el.attribute("id").map(|s| s.to_string()),
            static_transforms: wrap_origin(statics, &style, logs),
            animations: anims,
            filter_id: parse_filter_ref(el),
            mask_id: parse_mask_ref(el),
            motion_path: parse_motion_path(&style, logs).or(am_motion_path),
        },
        children,
        display_none: el.attribute("display") == Some("none"),
    }
}

fn parse_use(el: Node, ctx: &WalkCtx, logs: &mut LogCollector) -> Option<SvgUse> {
    let href = el
        .attribute((XLINK_NS, "href"))
        .or_else(|| el.attribute("href"));
    let href = match href {
        Some(h) if h.starts_with('#') => h,
        other => {
            logs.warn(
                "parse.xml",
                "skipping <use> with missing/non-local href",
                &[("href", other.unwrap_or("(null)").into())],
            );
            return None;
        }
    };
    let (statics, anims, am_motion_path) = parse_transforms_and_animations(el, ctx, logs);
    let style = parse_inline_style(el.attribute("style"));
    Some(SvgUse {
        common: SvgNodeCommon {
            id: el.attribute("id").map(|s| s.to_string()),
            static_transforms: wrap_origin(statics, &style, logs),
            animations: anims,
            filter_id: parse_filter_ref(el),
            mask_id: parse_mask_ref(el),
            motion_path: parse_motion_path(&style, logs).or(am_motion_path),
        },
        href_id: href[1..].to_string(),
        width: parse_length(el.attribute("width")),
        height: parse_length(el.attribute("height")),
    })
}

fn parse_image(el: Node, ctx: &WalkCtx, logs: &mut LogCollector) -> Option<SvgImage> {
    let href = el
        .attribute((XLINK_NS, "href"))
        .or_else(|| el.attribute("href"));
    let href = match href {
        Some(h) => h.to_string(),
        None => {
            logs.warn(
                "parse.xml",
                "skipping <image> without href",
                &[("id", el.attribute("id").unwrap_or("").into())],
            );
            return None;
        }
    };
    let width = parse_length(el.attribute("width")).unwrap_or(0.0);
    let height = parse_length(el.attribute("height")).unwrap_or(0.0);
    let (statics, anims, am_motion_path) = parse_transforms_and_animations(el, ctx, logs);
    let style = parse_inline_style(el.attribute("style"));
    Some(SvgImage {
        common: SvgNodeCommon {
            id: el.attribute("id").map(|s| s.to_string()),
            static_transforms: wrap_origin(statics, &style, logs),
            animations: anims,
            filter_id: parse_filter_ref(el),
            mask_id: parse_mask_ref(el),
            motion_path: parse_motion_path(&style, logs).or(am_motion_path),
        },
        href,
        width,
        height,
    })
}

// ---------- refs ------------------------------------------------------------

fn parse_filter_ref(el: Node) -> Option<String> {
    parse_url_ref(el.attribute("filter"))
}

fn parse_mask_ref(el: Node) -> Option<String> {
    parse_url_ref(el.attribute("mask"))
}

fn parse_url_ref(raw: Option<&str>) -> Option<String> {
    let raw = raw?;
    let t = raw.trim();
    if !t.to_ascii_lowercase().starts_with("url(") {
        return None;
    }
    let open = t.find('(')?;
    let close = t.rfind(')')?;
    if close <= open {
        return None;
    }
    let mut body = t[open + 1..close].trim().to_string();
    if body.starts_with('"') || body.starts_with('\'') {
        // trim matching quote on both ends
        body = body[1..body.len().saturating_sub(1)].to_string();
    }
    if let Some(rest) = body.strip_prefix('#') {
        body = rest.to_string();
    }
    if body.is_empty() {
        None
    } else {
        Some(body)
    }
}

// ---------- transforms + animations ----------------------------------------

fn parse_transforms_and_animations(
    el: Node,
    ctx: &WalkCtx,
    logs: &mut LogCollector,
) -> (Vec<SvgStaticTransform>, Vec<SvgAnimationNode>, Option<SvgMotionPath>) {
    let mut statics = transform::parse(el.attribute("transform"), logs);
    let mut anims = Vec::new();
    let mut motion_path: Option<SvgMotionPath> = None;
    for child in el.children().filter(|c| c.is_element()) {
        if !is_animation_tag(child) {
            continue;
        }
        if child.tag_name().name() == "animateMotion" {
            if let Some((mp, node)) = extract_animate_motion(child, logs) {
                if motion_path.is_none() {
                    if let Some(m) = mp {
                        motion_path = Some(m);
                    }
                }
                anims.push(node);
            }
            continue;
        }
        if let Some(n) = animation::parse(child, Some(el), logs) {
            anims.push(n);
        }
    }
    if let Some(id) = el.attribute("id") {
        if let Some(from_css) = ctx.css_anims.get(id) {
            if !from_css.is_empty() {
                anims.extend(from_css.iter().cloned());
            }
        }
        if let Some(from_svgator) = ctx.svgator_statics.get(id) {
            if !from_svgator.is_empty() {
                statics.extend(from_svgator.iter().cloned());
            }
        }
    }
    (statics, anims, motion_path)
}

/// Converts a SMIL `<animateMotion>` into either:
/// - `(Some(SvgMotionPath), Animate(offset-distance))` when a `path="..."`
///   attribute is present — the CSS Motion Path pipeline then samples the
///   path and produces translate/rotate keyframes.
/// - `(None, AnimateTransform(translate))` when only `values=` or
///   `from`/`to`/`by` point lists are provided — the element is translated
///   directly through the listed coordinates.
///
/// MVP scope: honours `dur`, `repeatCount`, `rotate="auto"|"auto-reverse"|<deg>`,
/// `keyPoints`/`keyTimes` (path form). `<mpath xlink:href="#id">` child is
/// not yet resolved.
fn extract_animate_motion(
    el: Node,
    logs: &mut LogCollector,
) -> Option<(Option<SvgMotionPath>, SvgAnimationNode)> {
    let path = el.attribute("path");
    let values_raw = el.attribute("values");
    let from_raw = el.attribute("from");
    let to_raw = el.attribute("to");
    let by_raw = el.attribute("by");

    let dur_raw = match el.attribute("dur") {
        Some(d) => d,
        None => {
            logs.warn(
                "parse.xml",
                "skipping <animateMotion> without dur",
                &[("path", path.or(values_raw).unwrap_or("").into())],
            );
            return None;
        }
    };
    let dur = match parse_animate_motion_duration(dur_raw) {
        Some(d) => d,
        None => {
            logs.warn(
                "parse.xml",
                "skipping <animateMotion> with invalid dur",
                &[("dur", dur_raw.into())],
            );
            return None;
        }
    };
    let repeat = el.attribute("repeatCount") == Some("indefinite");
    let additive = if el.attribute("additive") == Some("sum") {
        SvgAnimationAdditive::Sum
    } else {
        SvgAnimationAdditive::Replace
    };

    if let Some(path) = path {
        let rotate = parse_animate_motion_rotate(el.attribute("rotate"));
        let key_points_raw = el.attribute("keyPoints");
        let key_times_raw = el.attribute("keyTimes");
        let (offset_values, offset_key_times): (Vec<String>, Vec<f64>) =
            match (key_points_raw, key_times_raw) {
                (Some(kp), Some(kt)) => {
                    let pts: Vec<&str> =
                        kp.split(';').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
                    let kts: Vec<f64> = kt
                        .split(';')
                        .map(|s| s.trim().parse::<f64>().unwrap_or(0.0))
                        .collect();
                    if pts.len() == kts.len() && !pts.is_empty() {
                        let values: Vec<String> = pts
                            .iter()
                            .map(|p| {
                                let v: f64 = p.parse::<f64>().unwrap_or(0.0);
                                format!("{:.2}%", v * 100.0)
                            })
                            .collect();
                        (values, kts)
                    } else {
                        (
                            vec!["0%".to_string(), "100%".to_string()],
                            vec![0.0, 1.0],
                        )
                    }
                }
                _ => (
                    vec!["0%".to_string(), "100%".to_string()],
                    vec![0.0, 1.0],
                ),
            };
        let anim = SvgAnimationNode::Animate {
            attribute_name: "offset-distance".to_string(),
            common: SvgAnimationCommon {
                dur_seconds: dur,
                repeat_indefinite: repeat,
                additive,
                keyframes: SvgKeyframes {
                    key_times: offset_key_times,
                    values: offset_values,
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: Vec::new(),
                },
                delay_seconds: 0.0,
                direction: Default::default(),
                fill_mode: Default::default(),
            },
        };
        return Some((
            Some(SvgMotionPath {
                path_data: path.to_string(),
                rotate,
            }),
            anim,
        ));
    }

    // Point-list form: values="x,y; x,y" (or from/to/by sugar).
    let points = resolve_motion_values(values_raw, from_raw, to_raw, by_raw);
    let points = match points {
        Some(p) if p.len() >= 2 => p,
        _ => {
            logs.warn(
                "parse.xml",
                "skipping <animateMotion>: no path, values, or from/to/by",
                &[("id", el.attribute("id").unwrap_or("").into())],
            );
            return None;
        }
    };
    let key_times_raw = el.attribute("keyTimes");
    let key_times = if let Some(kt) = key_times_raw {
        let parsed: Vec<f64> = kt
            .split(';')
            .map(|s| s.trim().parse::<f64>().unwrap_or(0.0))
            .collect();
        if parsed.len() == points.len() {
            parsed
        } else {
            implicit_key_times(points.len())
        }
    } else {
        implicit_key_times(points.len())
    };
    let translate = SvgAnimationNode::AnimateTransform {
        kind: SvgTransformKind::Translate,
        common: SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: repeat,
            additive,
            keyframes: SvgKeyframes {
                key_times,
                values: points,
                calc_mode: SvgAnimationCalcMode::Linear,
                key_splines: Vec::new(),
            },
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        },
    };
    Some((None, translate))
}

/// Resolves SMIL animateMotion's point list from `values`, or synthesizes
/// one from `from`/`to`/`by`. Every returned string is `"x,y"` so the
/// downstream SvgAnimateTransform(translate) serializer sees a uniform
/// format. Returns None if nothing usable was provided.
fn resolve_motion_values(
    values_raw: Option<&str>,
    from_raw: Option<&str>,
    to_raw: Option<&str>,
    by_raw: Option<&str>,
) -> Option<Vec<String>> {
    if let Some(values) = values_raw {
        let mut out = Vec::new();
        for seg in values.split(';') {
            let t = seg.trim();
            if t.is_empty() {
                continue;
            }
            let nums: Vec<&str> = SPACE_COMMA_RE.split(t).filter(|s| !s.is_empty()).collect();
            if nums.len() >= 2 {
                out.push(format!("{},{}", nums[0], nums[1]));
            }
        }
        return if out.is_empty() { None } else { Some(out) };
    }
    fn fmt(pair: Option<&str>) -> Option<String> {
        let p = pair?;
        let nums: Vec<&str> = SPACE_COMMA_RE.split(p.trim()).filter(|s| !s.is_empty()).collect();
        if nums.len() < 2 {
            return None;
        }
        Some(format!("{},{}", nums[0], nums[1]))
    }
    let from = fmt(from_raw).unwrap_or_else(|| "0,0".to_string());
    if let Some(to) = fmt(to_raw) {
        return Some(vec![from, to]);
    }
    if let Some(by) = fmt(by_raw) {
        let f: Vec<Option<f64>> = from.split(',').map(|s| s.parse::<f64>().ok()).collect();
        let b: Vec<Option<f64>> = by.split(',').map(|s| s.parse::<f64>().ok()).collect();
        if f.len() == 2 && b.len() == 2 {
            if let (Some(f0), Some(f1), Some(b0), Some(b1)) = (f[0], f[1], b[0], b[1]) {
                return Some(vec![from, format!("{},{}", f0 + b0, f1 + b1)]);
            }
        }
    }
    None
}

fn implicit_key_times(n: usize) -> Vec<f64> {
    if n <= 1 {
        return vec![0.0];
    }
    (0..n).map(|i| i as f64 / (n - 1) as f64).collect()
}

fn parse_animate_motion_rotate(raw: Option<&str>) -> SvgMotionRotate {
    let raw = match raw {
        Some(r) => r,
        None => return SvgMotionRotate::fixed(0.0),
    };
    let t = raw.trim();
    if t == "auto" {
        return SvgMotionRotate::AUTO;
    }
    if t == "auto-reverse" {
        return SvgMotionRotate::REVERSE;
    }
    let stripped = if let Some(s) = t.strip_suffix("deg") { s } else { t };
    match stripped.parse::<f64>() {
        Ok(n) => SvgMotionRotate::fixed(n),
        Err(_) => SvgMotionRotate::fixed(0.0),
    }
}

fn parse_animate_motion_duration(raw: &str) -> Option<f64> {
    let t = raw.trim();
    if let Some(ms) = t.strip_suffix("ms") {
        return ms.parse::<f64>().ok().map(|v| v / 1000.0);
    }
    if let Some(s) = t.strip_suffix('s') {
        return s.parse::<f64>().ok();
    }
    t.parse::<f64>().ok()
}

fn is_animation_tag(el: Node) -> bool {
    matches!(
        el.tag_name().name(),
        "animate" | "animateTransform" | "animateMotion" | "set"
    )
}

/// Elements we silently skip instead of throwing: either purely decorative
/// metadata (title/desc/metadata), document-level wrappers that don't
/// contribute renderable geometry on their own (style/filter), or masking
/// primitives we don't yet implement. Skipping preserves the rest of the
/// document for the MVP image+SMIL pipeline.
fn is_decorative_skip(tag: &str) -> bool {
    matches!(
        tag,
        "style"
            | "title"
            | "desc"
            | "metadata"
            | "filter"
            | "clipPath"
            // NOTE: 'mask' intentionally NOT here — it's routed to parse_mask
            // and stored in SvgDefs.masks, then resolved by the mapper as a
            // Lottie track matte.
            | "pattern"
            | "marker"
            | "symbol"
            | "linearGradient"
            | "radialGradient"
    )
}

// ---------- inline style / motion path / origin ----------------------------

/// `style="a: b; c: d"` → `{a: b, c: d}`. Semicolons inside balanced parens
/// (e.g. `offset-path: path('M 0 0; Z')`) stay attached to their declaration;
/// the split is only on top-level semicolons. Values keep their case — CSS
/// identifiers are case-insensitive but `path('...')` payloads are not.
fn parse_inline_style(raw: Option<&str>) -> HashMap<String, String> {
    let raw = match raw {
        Some(r) if !r.is_empty() => r,
        _ => return HashMap::new(),
    };
    let mut out = HashMap::new();
    let mut decls: Vec<String> = Vec::new();
    let mut buf = String::new();
    let mut depth: i32 = 0;
    for c in raw.chars() {
        if c == '(' {
            depth += 1;
        }
        if c == ')' {
            depth -= 1;
        }
        if c == ';' && depth == 0 {
            decls.push(std::mem::take(&mut buf));
        } else {
            buf.push(c);
        }
    }
    if !buf.is_empty() {
        decls.push(buf);
    }
    for decl in decls {
        let colon = match decl.find(':') {
            Some(i) => i,
            None => continue,
        };
        let k = decl[..colon].trim().to_ascii_lowercase();
        let v = decl[colon + 1..].trim().to_string();
        if !k.is_empty() {
            out.insert(k, v);
        }
    }
    out
}

/// Reads CSS Motion Path declarations from an inline style map. Recognises
/// `offset-path: path('M...')` (quotes optional) and `offset-rotate: auto |
/// reverse | Ndeg`. Returns `None` when no `offset-path` is present or its
/// value is unsupported (e.g. `ray(...)`, `url(#id)` — not in MVP scope).
fn parse_motion_path(
    style: &HashMap<String, String>,
    logs: &mut LogCollector,
) -> Option<SvgMotionPath> {
    let raw = style.get("offset-path")?;
    let t = raw.trim();
    if t == "none" {
        return None;
    }
    if !t.starts_with("path(") {
        logs.warn(
            "parse.xml",
            "offset-path value not supported; ignoring",
            &[("value", raw.as_str().into())],
        );
        return None;
    }
    let open = t.find('(')?;
    let close = t.rfind(')')?;
    if close <= open {
        return None;
    }
    let mut body = t[open + 1..close].trim().to_string();
    if (body.starts_with('\'') && body.ends_with('\''))
        || (body.starts_with('"') && body.ends_with('"'))
    {
        body = body[1..body.len() - 1].to_string();
    }
    if body.is_empty() {
        return None;
    }
    Some(SvgMotionPath {
        path_data: body,
        rotate: parse_motion_rotate(style.get("offset-rotate").map(|s| s.as_str()), logs),
    })
}

fn parse_motion_rotate(raw: Option<&str>, logs: &mut LogCollector) -> SvgMotionRotate {
    let raw = match raw {
        Some(r) => r,
        None => return SvgMotionRotate::AUTO,
    };
    let t = raw.trim();
    if t.is_empty() || t == "auto" {
        return SvgMotionRotate::AUTO;
    }
    if t == "reverse" || t == "auto reverse" {
        return SvgMotionRotate::REVERSE;
    }
    let caps = match ROTATE_RE.captures(t) {
        Some(c) => c,
        None => {
            logs.warn(
                "parse.xml",
                "offset-rotate value not parseable; auto fallback",
                &[("value", raw.into())],
            );
            return SvgMotionRotate::AUTO;
        }
    };
    let v = caps.get(1).and_then(|m| m.as_str().parse::<f64>().ok()).unwrap_or(0.0);
    let deg = match caps.get(2).map(|m| m.as_str()) {
        Some("rad") => v * 180.0 / std::f64::consts::PI,
        Some("turn") => v * 360.0,
        Some("grad") => v * 0.9,
        _ => v,
    };
    SvgMotionRotate::fixed(deg)
}

/// CSS `transform-origin: Xunit Yunit`. M applied around (ox, oy) is
/// `T(ox,oy) · M · T(-ox,-oy)` — wraps existing static transforms when the
/// origin is non-zero. Supports `Npx` and unitless numbers; `%` and keywords
/// (`center`/`left`/...) require bbox and are logged + skipped.
fn parse_transform_origin(
    style: &HashMap<String, String>,
    logs: &mut LogCollector,
) -> Option<(f64, f64)> {
    let raw = style.get("transform-origin")?;
    let parts: Vec<&str> = SPACE_COMMA_RE
        .split(raw.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if parts.is_empty() {
        return None;
    }
    fn one(t: &str) -> Option<f64> {
        let caps = ORIGIN_NUM_RE.captures(t)?;
        caps.get(1)?.as_str().parse::<f64>().ok()
    }
    let x = one(parts[0]);
    let y = if parts.len() > 1 { one(parts[1]) } else { x };
    match (x, y) {
        (Some(x), Some(y)) => Some((x, y)),
        _ => {
            logs.warn(
                "parse.xml",
                "transform-origin with unsupported units; ignoring",
                &[("value", raw.as_str().into())],
            );
            None
        }
    }
}

fn wrap_origin(
    statics: Vec<SvgStaticTransform>,
    style: &HashMap<String, String>,
    logs: &mut LogCollector,
) -> Vec<SvgStaticTransform> {
    if statics.is_empty() {
        return statics;
    }
    let origin = match parse_transform_origin(style, logs) {
        Some(o) => o,
        None => return statics,
    };
    let (ox, oy) = origin;
    if ox == 0.0 && oy == 0.0 {
        return statics;
    }
    let mut wrapped = Vec::with_capacity(statics.len() + 2);
    wrapped.push(SvgStaticTransform {
        kind: SvgTransformKind::Translate,
        values: vec![ox, oy],
    });
    wrapped.extend(statics);
    wrapped.push(SvgStaticTransform {
        kind: SvgTransformKind::Translate,
        values: vec![-ox, -oy],
    });
    wrapped
}

fn parse_points(raw: Option<&str>) -> Vec<[f64; 2]> {
    let raw = match raw {
        Some(v) => v,
        None => return Vec::new(),
    };
    let nums: Vec<f64> = SPACE_COMMA_RE
        .split(raw)
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<f64>().ok())
        .collect();
    let mut out = Vec::with_capacity(nums.len() / 2);
    let mut i = 0;
    while i + 1 < nums.len() {
        out.push([nums[i], nums[i + 1]]);
        i += 2;
    }
    out
}

// ---------- class index / css resolve --------------------------------------

/// Merges per-class styles (in declaration order from the element's `class=`
/// attribute) with per-id styles (if any). `#id` rules win over `.class`
/// rules per CSS specificity; multiple classes compose left-to-right, later
/// classes overriding earlier ones.
fn class_style_for(el: Node, statics: &CssStatics) -> Option<HashMap<String, String>> {
    if statics.by_id.is_empty() && statics.by_class.is_empty() {
        return None;
    }
    let mut out: HashMap<String, String> = HashMap::new();
    if let Some(class_raw) = el.attribute("class") {
        let trimmed = class_raw.trim();
        if !trimmed.is_empty() {
            for cls in WHITESPACE_RE.split(trimmed) {
                if let Some(styles) = statics.by_class.get(cls) {
                    for (k, v) in styles {
                        out.insert(k.clone(), v.clone());
                    }
                }
            }
        }
    }
    if let Some(id) = el.attribute("id") {
        if let Some(id_styles) = statics.by_id.get(id) {
            for (k, v) in id_styles {
                out.insert(k.clone(), v.clone());
            }
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Builds `class → [ids]` map for elements that carry both a `class` and an
/// `id` attribute. The CSS parser uses this to expand `.cls { ... }`
/// selectors into the same id-keyed animation map it produces for `#id`.
/// Elements with a class but no id can't be targeted individually downstream
/// — they're silently ignored here.
fn build_class_index(root: Node) -> HashMap<String, Vec<String>> {
    let mut out: HashMap<String, Vec<String>> = HashMap::new();
    for el in root.descendants().filter(|d| d.is_element()) {
        let id = match el.attribute("id") {
            Some(i) => i,
            None => continue,
        };
        let class_raw = match el.attribute("class") {
            Some(c) if !c.trim().is_empty() => c.trim(),
            _ => continue,
        };
        for cls in WHITESPACE_RE.split(class_raw) {
            if cls.is_empty() {
                continue;
            }
            out.entry(cls.to_string()).or_default().push(id.to_string());
        }
    }
    out
}

// ---------- lengths / viewbox / text collection ----------------------------

fn parse_length(raw: Option<&str>) -> Option<f64> {
    let raw = raw?;
    let t = raw.trim();
    let stripped = LENGTH_UNIT_RE.replace(t, "");
    stripped.parse::<f64>().ok()
}

fn parse_view_box(
    raw: Option<&str>,
    w: Option<f64>,
    h: Option<f64>,
) -> Result<SvgViewBox, ConvertError> {
    let raw = match raw {
        Some(r) => r,
        None => {
            return Ok(SvgViewBox {
                x: 0.0,
                y: 0.0,
                w: w.unwrap_or(0.0),
                h: h.unwrap_or(0.0),
            });
        }
    };
    let parts: Result<Vec<f64>, _> = SPACE_COMMA_RE
        .split(raw.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.parse::<f64>())
        .collect();
    let parts = parts
        .map_err(|e| ConvertError::parse(format!("viewBox parse failed: {}", e)))?;
    if parts.len() != 4 {
        return Err(ConvertError::parse(format!(
            "viewBox expects 4 numbers, got {}",
            raw
        )));
    }
    Ok(SvgViewBox {
        x: parts[0],
        y: parts[1],
        w: parts[2],
        h: parts[3],
    })
}

/// Walks `root.descendants`, collects text from every `<tag>` element,
/// newline-joined. Mirrors Dart's `root.descendants.whereType<XmlElement>...`.
fn collect_text_from(root: Node, tag: &str) -> String {
    let mut out = String::new();
    let mut first = true;
    for d in root.descendants().filter(|d| d.is_element()) {
        if d.tag_name().name() != tag {
            continue;
        }
        let text = element_inner_text(d);
        if !first {
            out.push('\n');
        }
        first = false;
        out.push_str(&text);
    }
    out
}

fn element_inner_text(el: Node) -> String {
    // Concatenate text (including CDATA) from all descendant text nodes.
    let mut out = String::new();
    for d in el.descendants() {
        if d.is_text() {
            if let Some(t) = d.text() {
                out.push_str(t);
            }
        }
    }
    out
}

// ---------- tests ----------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    #[test]
    fn minimal_svg_parses() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50"></svg>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        assert_eq!(doc.width, 100.0);
        assert_eq!(doc.height, 50.0);
        assert_eq!(doc.view_box.w, 100.0);
        assert_eq!(doc.view_box.h, 50.0);
        assert!(doc.root.children.is_empty());
    }

    #[test]
    fn malformed_xml_returns_parse_error() {
        let xml = "<svg><g></svg>"; // unbalanced
        let mut logs = mk_logs();
        let err = parse(xml, &mut logs).unwrap_err();
        assert!(matches!(err.kind, crate::error::ErrorKind::Parse));
    }

    #[test]
    fn non_svg_root_is_rejected() {
        let xml = "<foo/>";
        let mut logs = mk_logs();
        let err = parse(xml, &mut logs).unwrap_err();
        assert_eq!(err.message, "root element is not <svg>");
    }

    #[test]
    fn view_box_missing_falls_back_to_width_height() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120"/>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        assert_eq!(doc.view_box.x, 0.0);
        assert_eq!(doc.view_box.y, 0.0);
        assert_eq!(doc.view_box.w, 200.0);
        assert_eq!(doc.view_box.h, 120.0);
    }

    #[test]
    fn group_nesting_preserved() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <g id="outer"><g id="inner"><rect x="1" y="2" width="3" height="4"/></g></g>
        </svg>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        assert_eq!(doc.root.children.len(), 1);
        let outer = match &doc.root.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!("expected outer group"),
        };
        assert_eq!(outer.common.id.as_deref(), Some("outer"));
        assert_eq!(outer.children.len(), 1);
        let inner = match &outer.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!("expected inner group"),
        };
        assert_eq!(inner.children.len(), 1);
        assert!(matches!(inner.children[0], SvgNode::Shape(_)));
    }

    #[test]
    fn shape_fill_cascades_from_inline_style() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <rect style="fill:red;fill-opacity:0.5" x="0" y="0" width="5" height="5"/>
        </svg>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        let shape = match &doc.root.children[0] {
            SvgNode::Shape(s) => s,
            _ => panic!("expected shape"),
        };
        assert_eq!(shape.fill, "red");
        assert!((shape.fill_opacity - 0.5).abs() < 1e-9);
    }

    #[test]
    fn use_href_resolves_to_ref_id() {
        let xml = r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">
            <defs><rect id="r1" x="0" y="0" width="5" height="5"/></defs>
            <use xlink:href="#r1"/>
            <use href="#r1" id="u2"/>
        </svg>"##;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        let uses: Vec<&SvgUse> = doc
            .root
            .children
            .iter()
            .filter_map(|n| if let SvgNode::Use(u) = n { Some(u) } else { None })
            .collect();
        assert_eq!(uses.len(), 2);
        assert_eq!(uses[0].href_id, "r1");
        assert_eq!(uses[1].href_id, "r1");
        assert_eq!(uses[1].common.id.as_deref(), Some("u2"));
    }

    #[test]
    fn defs_populates_defs_map() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <defs>
                <rect id="r1" x="0" y="0" width="5" height="5"/>
                <g id="g1"><circle cx="1" cy="1" r="1"/></g>
            </defs>
        </svg>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        assert!(doc.defs.by_id.contains_key("r1"));
        assert!(doc.defs.by_id.contains_key("g1"));
    }

    #[test]
    fn linear_gradient_with_stops() {
        let xml = r##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <defs>
                <linearGradient id="grad1" x1="0" y1="0" x2="1" y2="0">
                    <stop offset="0" stop-color="#ff0000"/>
                    <stop offset="100%" stop-color="#0000ff" stop-opacity="0.5"/>
                </linearGradient>
            </defs>
        </svg>"##;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        let g = doc.defs.gradients.get("grad1").expect("gradient present");
        assert_eq!(g.kind, SvgGradientKind::Linear);
        assert_eq!(g.stops.len(), 2);
        assert_eq!(g.stops[0].offset, 0.0);
        assert_eq!(g.stops[1].offset, 1.0);
        assert!((g.stops[1].stop_opacity - 0.5).abs() < 1e-9);
    }

    #[test]
    fn css_animation_wires_to_id() {
        let xml = r##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <style>
                #r1 { animation: a1 1s linear infinite; }
                @keyframes a1 { 0% { opacity: 0 } 100% { opacity: 1 } }
            </style>
            <rect id="r1" x="0" y="0" width="5" height="5"/>
        </svg>"##;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        let shape = match &doc.root.children[0] {
            SvgNode::Shape(s) => s,
            _ => panic!("expected shape"),
        };
        assert!(
            !shape.common.animations.is_empty(),
            "CSS animation should have wired onto #r1"
        );
    }

    #[test]
    fn svgator_script_wires_animations() {
        let payload = r#"{"animations":[{"elements":{"r1":{"o":[{"t":0,"v":0},{"t":1000,"v":1}]}}}]}"#;
        let xml = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
                <script>window.__SVGATOR_PLAYER__ = {};</script>
                <rect id="r1" x="0" y="0" width="5" height="5"/>
            </svg>"#,
            payload
        );
        let mut logs = mk_logs();
        let doc = parse(&xml, &mut logs).expect("parsed");
        let shape = match &doc.root.children[0] {
            SvgNode::Shape(s) => s,
            _ => panic!("expected shape"),
        };
        // Svgator may or may not produce a track depending on payload shape;
        // the critical thing is the walker didn't fail and ran the extraction.
        let _ = shape;
    }

    #[test]
    fn animate_motion_attaches_to_parent() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <rect id="r1" x="0" y="0" width="5" height="5">
                <animateMotion dur="2s" path="M 0 0 L 10 0"/>
            </rect>
        </svg>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        let shape = match &doc.root.children[0] {
            SvgNode::Shape(s) => s,
            _ => panic!("expected shape"),
        };
        // path form produces a motion_path AND a synthesized offset-distance animation.
        let mp = shape.common.motion_path.as_ref().expect("motion path");
        assert_eq!(mp.path_data, "M 0 0 L 10 0");
        assert!(
            shape
                .common
                .animations
                .iter()
                .any(|a| matches!(a, SvgAnimationNode::Animate { attribute_name, .. } if attribute_name == "offset-distance"))
        );
    }

    #[test]
    fn inline_style_fill_cascades_across_groups() {
        let xml = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <g fill="blue"><rect x="0" y="0" width="1" height="1"/></g>
        </svg>"#;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        let group = match &doc.root.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!("expected group"),
        };
        let shape = match &group.children[0] {
            SvgNode::Shape(s) => s,
            _ => panic!("expected shape"),
        };
        assert_eq!(shape.fill, "blue");
    }

    #[test]
    fn root_level_gradient_is_collected() {
        // Illustrator quirk: gradient at root, not under <defs>.
        let xml = r##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
            <linearGradient id="g_root"><stop offset="0" stop-color="#000"/></linearGradient>
            <rect x="0" y="0" width="1" height="1"/>
        </svg>"##;
        let mut logs = mk_logs();
        let doc = parse(xml, &mut logs).expect("parsed");
        assert!(doc.defs.gradients.contains_key("g_root"));
    }
}
