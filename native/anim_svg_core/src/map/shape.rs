//! Port of `lib/src/data/mappers/shape_mapper.dart`.
//!
//! Converts an `SvgShape` into the `Vec<LottieShapeItem>` that lives inside a
//! Lottie shape layer's `it:` array: geometry + fill + stroke + gradient fill
//! + trim paths. Transforms are handled by the caller.

use crate::domain::{
    BezierHandle, LottieGradientKeyframe, LottieGradientKind, LottieGradientStops,
    LottieScalarKeyframe, LottieScalarProp, LottieShapeFill, LottieShapeGeometry,
    LottieShapeGradientFill, LottieShapeItem, LottieShapeKind, LottieShapeStroke,
    LottieShapeTrimPath, SvgAnimationCalcMode, SvgAnimationNode, SvgDefs, SvgGradient,
    SvgGradientKind, SvgGradientUnits, SvgKeyframes, SvgShape, SvgShapeKind, SvgStop,
};
use crate::log::LogCollector;
use crate::map::keyspline;
use crate::parse::path_data::{self, CubicContour};

const FRAME_RATE: f64 = 60.0;

/// Public entry point. Mirrors the Dart `ShapeMapper.map` top-level call.
pub fn map(shape: &SvgShape, defs: &SvgDefs, logs: &mut LogCollector) -> Vec<LottieShapeItem> {
    let geometry = build_geometry(shape, logs);
    if geometry.is_empty() {
        return Vec::new();
    }

    let mut out: Vec<LottieShapeItem> = Vec::new();
    out.extend(geometry);
    if let Some(fill) = build_fill_item(shape, defs, logs) {
        out.push(fill);
    }
    if let Some(stroke) = build_stroke_item(shape, logs) {
        out.push(LottieShapeItem::Stroke(stroke));
    }
    if let Some(trim) = build_trim_path_item(shape, logs) {
        out.push(LottieShapeItem::TrimPath(trim));
    }
    out
}

// ---------------------------------------------------------------------------
// Fill
// ---------------------------------------------------------------------------

fn build_fill_item(
    node: &SvgShape,
    defs: &SvgDefs,
    logs: &mut LogCollector,
) -> Option<LottieShapeItem> {
    let fill_raw = node.fill.trim();
    if let Some(url_id) = gradient_href_id(fill_raw) {
        if let Some(grad) = defs.gradients.get(&url_id) {
            if let Some(gf) = build_gradient_fill(grad, node, logs) {
                return Some(LottieShapeItem::GradientFill(gf));
            }
        } else {
            logs.warn(
                "map.shape",
                "gradient id not found → grey fallback",
                &[("fill", fill_raw.into())],
            );
        }
        let opacity = node.fill_opacity * node.opacity * 100.0;
        return Some(LottieShapeItem::Fill(LottieShapeFill {
            color: [0.5, 0.5, 0.5, 1.0],
            opacity,
        }));
    }

    let fill_color = parse_color(fill_raw, logs)?;
    // Fold alpha from rgba()/hsla() into fill_opacity; keep RGBA[3]=1.
    let color_alpha = fill_color[3];
    let rgba = [fill_color[0], fill_color[1], fill_color[2], 1.0];
    let fill_opacity = node.fill_opacity * node.opacity * color_alpha * 100.0;
    Some(LottieShapeItem::Fill(LottieShapeFill {
        color: rgba,
        opacity: fill_opacity,
    }))
}

fn build_stroke_item(node: &SvgShape, logs: &mut LogCollector) -> Option<LottieShapeStroke> {
    let raw = node.stroke.as_deref()?.trim();
    if raw.is_empty() || raw.eq_ignore_ascii_case("none") {
        return None;
    }
    let rgba = if raw.to_ascii_lowercase().starts_with("url(") {
        logs.warn(
            "map.shape",
            "gradient stroke not yet supported → fallback grey",
            &[("stroke", raw.into())],
        );
        Some([0.5, 0.5, 0.5, 1.0])
    } else {
        parse_color(raw, logs)
    };
    let rgba = rgba?;
    let color_alpha = rgba[3];
    let color = [rgba[0], rgba[1], rgba[2], 1.0];
    let opacity = node.stroke_opacity * node.opacity * color_alpha * 100.0;
    Some(LottieShapeStroke {
        color,
        opacity,
        width: if node.stroke_width > 0.0 {
            node.stroke_width
        } else {
            1.0
        },
        line_cap: map_line_cap(node.stroke_linecap.as_deref()),
        line_join: map_line_join(node.stroke_linejoin.as_deref()),
        miter_limit: 4.0,
    })
}

fn map_line_cap(cap: Option<&str>) -> i32 {
    match cap.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("round") => 2,
        Some("square") => 3,
        _ => 1,
    }
}

fn map_line_join(join: Option<&str>) -> i32 {
    match join.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("round") => 2,
        Some("bevel") => 3,
        _ => 1,
    }
}

// ---------------------------------------------------------------------------
// Trim paths (stroke-dashoffset animation)
// ---------------------------------------------------------------------------

fn build_trim_path_item(node: &SvgShape, logs: &mut LogCollector) -> Option<LottieShapeTrimPath> {
    let stroke_raw = node.stroke.as_deref()?.trim();
    if stroke_raw.eq_ignore_ascii_case("none") {
        return None;
    }

    // Find an <animate attributeName="stroke-dashoffset">.
    let (attr_keyframes, dur_seconds) = find_animate(&node.common.animations, "stroke-dashoffset")?;
    if dur_seconds <= 0.0 {
        return None;
    }

    let parsed_vals: Vec<Option<f64>> = attr_keyframes
        .values
        .iter()
        .map(|v| v.trim().parse::<f64>().ok())
        .collect();

    let dash_from_array = first_numeric(node.stroke_dasharray.as_deref());
    let mut length = if let Some(v) = dash_from_array {
        if v > 0.0 { v } else { 0.0 }
    } else {
        0.0
    };
    if length <= 0.0 {
        let max = parsed_vals
            .iter()
            .filter_map(|v| *v)
            .fold(0.0_f64, |p, v| if v.abs() > p { v.abs() } else { p });
        length = max;
    }
    if length <= 0.0 {
        logs.warn(
            "map.shape",
            "stroke-dashoffset animated but no path length; trim skipped",
            &[("id", node.common.id.clone().unwrap_or_default().into())],
        );
        return None;
    }

    let key_times = &attr_keyframes.key_times;
    let mut kfs: Vec<LottieScalarKeyframe> = Vec::new();
    for (i, val) in parsed_vals.iter().enumerate() {
        let v = match val {
            Some(v) => *v,
            None => {
                logs.warn(
                    "map.shape",
                    "stroke-dashoffset keyframe not numeric → trim skipped",
                    &[
                        ("id", node.common.id.clone().unwrap_or_default().into()),
                        ("index", (i as u64).into()),
                    ],
                );
                return None;
            }
        };
        let end_pct = (1.0 - (v / length)).clamp(0.0, 1.0) * 100.0;
        let time = key_times[i] * dur_seconds * FRAME_RATE;

        let mut bez_in: Option<BezierHandle> = None;
        let mut bez_out: Option<BezierHandle> = None;
        if i == 0 {
            bez_out = keyspline::segment(attr_keyframes, 0, logs).0;
        } else {
            bez_in = keyspline::segment(attr_keyframes, i - 1, logs).1;
            if i < parsed_vals.len() - 1 {
                bez_out = keyspline::segment(attr_keyframes, i, logs).0;
            }
        }

        kfs.push(LottieScalarKeyframe {
            time,
            start: end_pct,
            hold: keyspline::hold(attr_keyframes),
            bezier_in: bez_in,
            bezier_out: bez_out,
        });
    }

    Some(LottieShapeTrimPath {
        start: LottieScalarProp::Static { value: 0.0 },
        end: LottieScalarProp::Animated { keyframes: kfs },
        offset: LottieScalarProp::Static { value: 0.0 },
    })
}

/// Finds the first `<animate>` animation targeting `attr`. Returns its
/// keyframes and duration.
fn find_animate<'a>(
    animations: &'a [SvgAnimationNode],
    attr: &str,
) -> Option<(&'a SvgKeyframes, f64)> {
    for a in animations {
        if let SvgAnimationNode::Animate {
            attribute_name,
            common,
        } = a
        {
            if attribute_name == attr {
                return Some((&common.keyframes, common.dur_seconds));
            }
        }
    }
    None
}

fn first_numeric(raw: Option<&str>) -> Option<f64> {
    let t = raw?.trim();
    if t.is_empty() {
        return None;
    }
    for tok in t.split(|c: char| c == ',' || c.is_whitespace()) {
        if tok.is_empty() {
            continue;
        }
        if let Ok(n) = tok.parse::<f64>() {
            return Some(n);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Gradient fill
// ---------------------------------------------------------------------------

fn gradient_href_id(fill: &str) -> Option<String> {
    let t = fill.trim();
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
        if body.len() >= 2 {
            body = body[1..body.len() - 1].to_string();
        }
    }
    if body.starts_with('#') {
        body = body[1..].to_string();
    }
    if body.is_empty() {
        None
    } else {
        Some(body)
    }
}

fn build_gradient_fill(
    grad: &SvgGradient,
    node: &SvgShape,
    logs: &mut LogCollector,
) -> Option<LottieShapeGradientFill> {
    if grad.stops.is_empty() {
        logs.warn(
            "map.shape",
            "gradient has no stops → fallback",
            &[("id", grad.id.clone().into())],
        );
        return None;
    }
    let (start_pt, end_pt) = gradient_endpoints(grad, node);
    let color_count = grad.stops.len();

    let any_animated = grad.stops.iter().any(|s| !s.animations.is_empty());
    let stops = if !any_animated {
        LottieGradientStops::Static {
            values: flat_stops(
                &grad.stops,
                &grad.stops.iter().map(|s| s.offset).collect::<Vec<_>>(),
                logs,
            ),
        }
    } else {
        animated_stops(&grad.stops, logs)
    };

    let opacity = node.fill_opacity * node.opacity * 100.0;
    Some(LottieShapeGradientFill {
        kind: match grad.kind {
            SvgGradientKind::Radial => LottieGradientKind::Radial,
            SvgGradientKind::Linear => LottieGradientKind::Linear,
        },
        color_stop_count: color_count,
        start_point: [start_pt[0], start_pt[1]],
        end_point: [end_pt[0], end_pt[1]],
        stops,
        opacity,
    })
}

fn gradient_endpoints(grad: &SvgGradient, node: &SvgShape) -> ([f64; 2], [f64; 2]) {
    let (mut start, mut end): ([f64; 2], [f64; 2]);
    if grad.units == SvgGradientUnits::ObjectBoundingBox {
        let bb = shape_bounding_box(node);
        let map_x = |u: f64| bb.x + u * bb.w;
        let map_y = |v: f64| bb.y + v * bb.h;
        if grad.kind == SvgGradientKind::Radial {
            start = [map_x(grad.cx), map_y(grad.cy)];
            end = [map_x(grad.cx + grad.r), map_y(grad.cy)];
        } else {
            start = [map_x(grad.x1), map_y(grad.y1)];
            end = [map_x(grad.x2), map_y(grad.y2)];
        }
    } else if grad.kind == SvgGradientKind::Radial {
        start = [grad.cx, grad.cy];
        end = [grad.cx + grad.r, grad.cy];
    } else {
        start = [grad.x1, grad.y1];
        end = [grad.x2, grad.y2];
    }
    if let Some(gt) = &grad.gradient_transform {
        if gt.len() == 6 {
            start = apply_affine(gt, start[0], start[1]);
            end = apply_affine(gt, end[0], end[1]);
        }
    }
    (start, end)
}

fn apply_affine(m: &[f64], x: f64, y: f64) -> [f64; 2] {
    [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]]
}

#[derive(Clone, Copy)]
struct Bbox {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

fn shape_bounding_box(node: &SvgShape) -> Bbox {
    match node.kind {
        SvgShapeKind::Rect => Bbox {
            x: node.x,
            y: node.y,
            w: node.width,
            h: node.height,
        },
        SvgShapeKind::Circle => Bbox {
            x: node.cx - node.r,
            y: node.cy - node.r,
            w: node.r * 2.0,
            h: node.r * 2.0,
        },
        SvgShapeKind::Ellipse => Bbox {
            x: node.cx - node.rx,
            y: node.cy - node.ry,
            w: node.rx * 2.0,
            h: node.ry * 2.0,
        },
        SvgShapeKind::Line => {
            let min_x = node.x1.min(node.x2);
            let min_y = node.y1.min(node.y2);
            Bbox {
                x: min_x,
                y: min_y,
                w: (node.x2 - node.x1).abs(),
                h: (node.y2 - node.y1).abs(),
            }
        }
        SvgShapeKind::Polyline | SvgShapeKind::Polygon | SvgShapeKind::Path => Bbox {
            x: 0.0,
            y: 0.0,
            w: 1.0,
            h: 1.0,
        },
    }
}

fn flat_stops(stops: &[SvgStop], offsets: &[f64], logs: &mut LogCollector) -> Vec<f64> {
    let mut color_part: Vec<f64> = Vec::new();
    let mut opacity_part: Vec<f64> = Vec::new();
    let mut has_alpha = false;
    for (i, s) in stops.iter().enumerate() {
        let off = offsets[i].clamp(0.0, 1.0);
        let rgba = parse_color(&s.color, logs).unwrap_or([0.0, 0.0, 0.0, 1.0]);
        color_part.extend_from_slice(&[off, rgba[0], rgba[1], rgba[2]]);
        opacity_part.extend_from_slice(&[off, s.stop_opacity]);
        if (s.stop_opacity - 1.0).abs() > 1e-6 {
            has_alpha = true;
        }
    }
    if has_alpha {
        color_part.extend_from_slice(&opacity_part);
    }
    color_part
}

fn animated_stops(stops: &[SvgStop], logs: &mut LogCollector) -> LottieGradientStops {
    // Max duration across stop animations; union of sample times (plus 0/1).
    let mut dur: f64 = 0.0;
    let mut sample_times: Vec<f64> = vec![0.0, 1.0];
    for s in stops {
        for a in &s.animations {
            if let SvgAnimationNode::Animate {
                attribute_name,
                common,
            } = a
            {
                if attribute_name != "offset" {
                    continue;
                }
                if common.dur_seconds > dur {
                    dur = common.dur_seconds;
                }
                for &t in &common.keyframes.key_times {
                    if !sample_times.iter().any(|x| (*x - t).abs() < 1e-12) {
                        sample_times.push(t);
                    }
                }
            }
        }
    }

    if dur <= 0.0 {
        let offsets: Vec<f64> = stops.iter().map(|s| s.offset).collect();
        return LottieGradientStops::Animated {
            keyframes: vec![LottieGradientKeyframe {
                time: 0.0,
                values: flat_stops(stops, &offsets, logs),
                hold: false,
            }],
        };
    }

    sample_times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mut kfs: Vec<LottieGradientKeyframe> = Vec::new();
    for t in &sample_times {
        let offs: Vec<f64> = stops.iter().map(|s| sample_stop_offset(s, *t)).collect();
        kfs.push(LottieGradientKeyframe {
            time: *t * dur * FRAME_RATE,
            values: flat_stops(stops, &offs, logs),
            hold: false,
        });
    }
    LottieGradientStops::Animated { keyframes: kfs }
}

fn sample_stop_offset(s: &SvgStop, progress: f64) -> f64 {
    for a in &s.animations {
        if let SvgAnimationNode::Animate {
            attribute_name,
            common,
        } = a
        {
            if attribute_name != "offset" {
                continue;
            }
            let kt = &common.keyframes.key_times;
            let vals: Vec<f64> = common
                .keyframes
                .values
                .iter()
                .map(|v| v.trim().parse::<f64>().unwrap_or(s.offset))
                .collect();
            if kt.is_empty() || vals.is_empty() {
                continue;
            }
            if progress <= kt[0] {
                return vals[0];
            }
            if progress >= *kt.last().unwrap() {
                return *vals.last().unwrap();
            }
            for i in 0..kt.len() - 1 {
                if progress >= kt[i] && progress <= kt[i + 1] {
                    let span = kt[i + 1] - kt[i];
                    let alpha = if span == 0.0 {
                        0.0
                    } else {
                        (progress - kt[i]) / span
                    };
                    return vals[i] + (vals[i + 1] - vals[i]) * alpha;
                }
            }
        }
    }
    s.offset
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

fn build_geometry(node: &SvgShape, logs: &mut LogCollector) -> Vec<LottieShapeItem> {
    match node.kind {
        SvgShapeKind::Rect => vec![LottieShapeItem::Geometry(LottieShapeGeometry {
            kind: LottieShapeKind::Rect,
            rect_position: [node.x + node.width / 2.0, node.y + node.height / 2.0],
            rect_size: [node.width, node.height],
            rect_roundness: if node.rx > 0.0 { node.rx } else { node.ry },
            ..LottieShapeGeometry::default()
        })],
        SvgShapeKind::Circle => vec![LottieShapeItem::Geometry(LottieShapeGeometry {
            kind: LottieShapeKind::Ellipse,
            ellipse_position: [node.cx, node.cy],
            ellipse_size: [node.r * 2.0, node.r * 2.0],
            ..LottieShapeGeometry::default()
        })],
        SvgShapeKind::Ellipse => vec![LottieShapeItem::Geometry(LottieShapeGeometry {
            kind: LottieShapeKind::Ellipse,
            ellipse_position: [node.cx, node.cy],
            ellipse_size: [node.rx * 2.0, node.ry * 2.0],
            ..LottieShapeGeometry::default()
        })],
        SvgShapeKind::Line => vec![LottieShapeItem::Geometry(LottieShapeGeometry {
            kind: LottieShapeKind::Path,
            vertices: vec![[node.x1, node.y1], [node.x2, node.y2]],
            in_tangents: vec![[0.0, 0.0], [0.0, 0.0]],
            out_tangents: vec![[0.0, 0.0], [0.0, 0.0]],
            closed: false,
            ..LottieShapeGeometry::default()
        })],
        SvgShapeKind::Polyline | SvgShapeKind::Polygon => {
            if node.points.is_empty() {
                logs.warn(
                    "map.shape",
                    "polyline/polygon has no points",
                    &[("kind", format!("{:?}", node.kind).to_lowercase().into())],
                );
                return Vec::new();
            }
            let contour = path_data::poly_contour(
                node.points.clone(),
                node.kind == SvgShapeKind::Polygon,
            );
            vec![LottieShapeItem::Geometry(contour_to_geometry(contour))]
        }
        SvgShapeKind::Path => {
            let d = match &node.d {
                Some(d) if !d.trim().is_empty() => d.clone(),
                _ => {
                    logs.warn(
                        "map.shape",
                        "path has no d attribute",
                        &[("id", node.common.id.clone().unwrap_or_default().into())],
                    );
                    return Vec::new();
                }
            };
            // Animated `d`?
            if let Some(d_anim) = find_animate_node(&node.common.animations, "d") {
                if let Some(animated) = build_animated_path(node, d_anim, logs) {
                    return vec![LottieShapeItem::Geometry(animated)];
                }
            }
            let contours = path_data::parse(&d, true, logs);
            if contours.is_empty() {
                return Vec::new();
            }
            contours
                .into_iter()
                .map(|c| LottieShapeItem::Geometry(contour_to_geometry(c)))
                .collect()
        }
    }
}

/// Finds the first `<animate>` node for `attr`, returning the whole node.
fn find_animate_node<'a>(
    animations: &'a [SvgAnimationNode],
    attr: &str,
) -> Option<&'a SvgAnimationNode> {
    animations.iter().find(|a| {
        matches!(
            a,
            SvgAnimationNode::Animate { attribute_name, .. } if attribute_name == attr
        )
    })
}

fn build_animated_path(
    node: &SvgShape,
    anim: &SvgAnimationNode,
    logs: &mut LogCollector,
) -> Option<LottieShapeGeometry> {
    let common = anim.common();
    let values = &common.keyframes.values;
    let key_times = &common.keyframes.key_times;
    if values.len() < 2 || key_times.len() != values.len() {
        return None;
    }
    if common.dur_seconds <= 0.0 {
        return None;
    }

    let mut contours: Vec<CubicContour> = Vec::new();
    let mut warned_multi = false;
    for (i, v) in values.iter().enumerate() {
        let parsed = path_data::parse(v, false, logs);
        if parsed.is_empty() {
            logs.warn(
                "map.shape",
                "path keyframe failed to parse → static fallback",
                &[
                    ("id", node.common.id.clone().unwrap_or_default().into()),
                    ("index", (i as u64).into()),
                ],
            );
            return None;
        }
        if parsed.len() > 1 && !warned_multi {
            logs.warn(
                "map.shape",
                "multi-subpath path animation → animating first subpath only",
                &[("id", node.common.id.clone().unwrap_or_default().into())],
            );
            warned_multi = true;
        }
        contours.push(parsed.into_iter().next().unwrap());
    }

    let first_count = contours[0].vertices.len();
    let first_closed = contours[0].closed;
    for (i, c) in contours.iter().enumerate().skip(1) {
        if c.vertices.len() != first_count || c.closed != first_closed {
            logs.warn(
                "map.shape",
                "path keyframes have mismatched topology → static fallback",
                &[
                    ("id", node.common.id.clone().unwrap_or_default().into()),
                    ("expected", (first_count as u64).into()),
                    ("got", (c.vertices.len() as u64).into()),
                ],
            );
            let _ = i;
            return None;
        }
    }

    let splines = &common.keyframes.key_splines;
    let use_splines = common.keyframes.calc_mode == SvgAnimationCalcMode::Spline
        && splines.len() == values.len().saturating_sub(1);
    let hold = common.keyframes.calc_mode == SvgAnimationCalcMode::Discrete;

    let mut kfs: Vec<crate::domain::LottieShapePathKeyframe> = Vec::new();
    for (i, c) in contours.iter().enumerate() {
        let (mut b_in, mut b_out) = (None, None);
        if use_splines && i < splines.len() {
            let s = splines[i];
            b_out = Some(BezierHandle { x: s.x1, y: s.y1 });
            b_in = Some(BezierHandle { x: s.x2, y: s.y2 });
        }
        kfs.push(crate::domain::LottieShapePathKeyframe {
            time: key_times[i] * common.dur_seconds * FRAME_RATE,
            vertices: c.vertices.clone(),
            in_tangents: c.in_tangents.clone(),
            out_tangents: c.out_tangents.clone(),
            closed: c.closed,
            hold,
            bezier_in: b_in,
            bezier_out: b_out,
        });
    }

    let first = &contours[0];
    Some(LottieShapeGeometry {
        kind: LottieShapeKind::Path,
        vertices: first.vertices.clone(),
        in_tangents: first.in_tangents.clone(),
        out_tangents: first.out_tangents.clone(),
        closed: first.closed,
        path_keyframes: Some(kfs),
        ..LottieShapeGeometry::default()
    })
}

fn contour_to_geometry(c: CubicContour) -> LottieShapeGeometry {
    LottieShapeGeometry {
        kind: LottieShapeKind::Path,
        vertices: c.vertices,
        in_tangents: c.in_tangents,
        out_tangents: c.out_tangents,
        closed: c.closed,
        ..LottieShapeGeometry::default()
    }
}

// ---------------------------------------------------------------------------
// Colour parsing
// ---------------------------------------------------------------------------

/// Parses a CSS-ish colour. Returns `None` for `none` / `transparent` /
/// empty. Falls back to black with a warn for unrecognised values (matches
/// the Dart behaviour — Dart returns `[0,0,0,1]` as a last resort).
fn parse_color(raw: &str, logs: &mut LogCollector) -> Option<[f64; 4]> {
    let t = raw.trim().to_ascii_lowercase();
    if t.is_empty() || t == "none" || t == "transparent" {
        return None;
    }
    if t.starts_with("url(") {
        logs.warn(
            "map.shape",
            "gradient/pattern fill not yet supported → fallback grey",
            &[("fill", raw.into())],
        );
        return Some([0.5, 0.5, 0.5, 1.0]);
    }
    if t.starts_with('#') {
        return Some(parse_hex(&t, logs));
    }
    if t.starts_with("rgb") {
        return Some(parse_rgb_fn(&t, logs));
    }
    if t.starts_with("hsl") {
        return Some(parse_hsl_fn(&t, logs));
    }
    if let Some(c) = named_color(&t) {
        return Some(c);
    }
    logs.warn(
        "map.shape",
        "unrecognised colour value",
        &[("fill", raw.into())],
    );
    Some([0.0, 0.0, 0.0, 1.0])
}

fn parse_hex(hex: &str, logs: &mut LogCollector) -> [f64; 4] {
    let s = &hex[1..];
    let expanded: String = if s.len() == 3 {
        let b = s.as_bytes();
        format!(
            "{0}{0}{1}{1}{2}{2}",
            b[0] as char, b[1] as char, b[2] as char
        )
    } else {
        s.to_string()
    };
    if expanded.len() != 6 {
        logs.warn(
            "map.shape",
            "unsupported hex colour",
            &[("fill", hex.into())],
        );
        return [0.0, 0.0, 0.0, 1.0];
    }
    let n = match u32::from_str_radix(&expanded, 16) {
        Ok(n) => n,
        Err(_) => {
            logs.warn(
                "map.shape",
                "malformed hex colour",
                &[("fill", hex.into())],
            );
            return [0.0, 0.0, 0.0, 1.0];
        }
    };
    let r = ((n >> 16) & 0xFF) as f64 / 255.0;
    let g = ((n >> 8) & 0xFF) as f64 / 255.0;
    let b = (n & 0xFF) as f64 / 255.0;
    [r, g, b, 1.0]
}

fn split_fn_args(raw: &str) -> Option<Vec<String>> {
    let open = raw.find('(')?;
    let close = raw.rfind(')')?;
    if close <= open {
        return None;
    }
    let body = &raw[open + 1..close];
    Some(
        body.split(|c: char| c == ',' || c == '/' || c.is_whitespace())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect(),
    )
}

fn parse_rgb_fn(raw: &str, logs: &mut LogCollector) -> [f64; 4] {
    let parts = match split_fn_args(raw) {
        Some(p) => p,
        None => return [0.0, 0.0, 0.0, 1.0],
    };
    if parts.len() < 3 {
        logs.warn(
            "map.shape",
            "rgb() needs 3+ components",
            &[("raw", raw.into())],
        );
        return [0.0, 0.0, 0.0, 1.0];
    }
    let chan = |s: &str| -> f64 {
        if let Some(pct) = s.strip_suffix('%') {
            pct.parse::<f64>().unwrap_or(0.0) / 100.0
        } else {
            s.parse::<f64>().unwrap_or(0.0) / 255.0
        }
    };
    let r = chan(&parts[0]);
    let g = chan(&parts[1]);
    let b = chan(&parts[2]);
    let a = if parts.len() > 3 {
        parts[3].parse::<f64>().unwrap_or(1.0)
    } else {
        1.0
    };
    [r, g, b, a]
}

fn parse_hsl_fn(raw: &str, logs: &mut LogCollector) -> [f64; 4] {
    let parts = match split_fn_args(raw) {
        Some(p) => p,
        None => return [0.0, 0.0, 0.0, 1.0],
    };
    if parts.len() < 3 {
        logs.warn(
            "map.shape",
            "hsl() needs 3+ components",
            &[("raw", raw.into())],
        );
        return [0.0, 0.0, 0.0, 1.0];
    }
    let parse_hue = |s: &str| -> f64 {
        if let Some(v) = s.strip_suffix("deg") {
            return v.parse::<f64>().unwrap_or(0.0) % 360.0;
        }
        if let Some(v) = s.strip_suffix("turn") {
            let n = v.parse::<f64>().unwrap_or(0.0);
            return (n * 360.0) % 360.0;
        }
        if let Some(v) = s.strip_suffix("rad") {
            let n = v.parse::<f64>().unwrap_or(0.0);
            return (n * 180.0 / std::f64::consts::PI) % 360.0;
        }
        s.parse::<f64>().unwrap_or(0.0) % 360.0
    };
    let parse_pct = |s: &str| -> f64 {
        if let Some(v) = s.strip_suffix('%') {
            (v.parse::<f64>().unwrap_or(0.0) / 100.0).clamp(0.0, 1.0)
        } else {
            s.parse::<f64>().unwrap_or(0.0).clamp(0.0, 1.0)
        }
    };
    let parse_alpha = |s: &str| -> f64 {
        if let Some(v) = s.strip_suffix('%') {
            (v.parse::<f64>().unwrap_or(100.0) / 100.0).clamp(0.0, 1.0)
        } else {
            s.parse::<f64>().unwrap_or(1.0).clamp(0.0, 1.0)
        }
    };
    let h = parse_hue(&parts[0]);
    let s = parse_pct(&parts[1]);
    let l = parse_pct(&parts[2]);
    let a = if parts.len() > 3 {
        parse_alpha(&parts[3])
    } else {
        1.0
    };

    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = h / 60.0;
    let x = c * (1.0 - ((hp % 2.0) - 1.0).abs());
    let (r1, g1, b1) = if hp < 1.0 {
        (c, x, 0.0)
    } else if hp < 2.0 {
        (x, c, 0.0)
    } else if hp < 3.0 {
        (0.0, c, x)
    } else if hp < 4.0 {
        (0.0, x, c)
    } else if hp < 5.0 {
        (x, 0.0, c)
    } else {
        (c, 0.0, x)
    };
    let m = l - c / 2.0;
    [r1 + m, g1 + m, b1 + m, a]
}

fn named_color(name: &str) -> Option<[f64; 4]> {
    match name {
        "black" => Some([0.0, 0.0, 0.0, 1.0]),
        "white" => Some([1.0, 1.0, 1.0, 1.0]),
        "red" => Some([1.0, 0.0, 0.0, 1.0]),
        "green" => Some([0.0, 0.5, 0.0, 1.0]),
        "blue" => Some([0.0, 0.0, 1.0, 1.0]),
        "yellow" => Some([1.0, 1.0, 0.0, 1.0]),
        "cyan" => Some([0.0, 1.0, 1.0, 1.0]),
        "magenta" => Some([1.0, 0.0, 1.0, 1.0]),
        "grey" | "gray" => Some([0.5, 0.5, 0.5, 1.0]),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{SvgAnimationCommon, SvgAnimationAdditive, SvgKeyframes};
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn base_shape(kind: SvgShapeKind) -> SvgShape {
        SvgShape {
            kind,
            ..SvgShape::default()
        }
    }

    // ---- colour parsing ----

    #[test]
    fn parse_hex_short_form() {
        let mut logs = mk_logs();
        let c = parse_color("#f00", &mut logs).unwrap();
        assert!((c[0] - 1.0).abs() < 1e-9);
        assert!(c[1].abs() < 1e-9);
        assert!(c[2].abs() < 1e-9);
        assert!((c[3] - 1.0).abs() < 1e-9);
    }

    #[test]
    fn parse_rgb_fn_basic() {
        let mut logs = mk_logs();
        let c = parse_color("rgb(255, 128, 0)", &mut logs).unwrap();
        assert!((c[0] - 1.0).abs() < 1e-9);
        assert!((c[1] - 128.0 / 255.0).abs() < 1e-9);
        assert!(c[2].abs() < 1e-9);
    }

    #[test]
    fn parse_named_color_blue() {
        let mut logs = mk_logs();
        let c = parse_color("blue", &mut logs).unwrap();
        assert_eq!(c, [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn missing_fill_defaults_to_none() {
        // fill="none" → no fill item emitted; geometry still present.
        let mut shape = base_shape(SvgShapeKind::Rect);
        shape.width = 10.0;
        shape.height = 10.0;
        shape.fill = "none".to_string();
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        assert_eq!(out.len(), 1);
        assert!(matches!(out[0], LottieShapeItem::Geometry(_)));
    }

    #[test]
    fn rect_geometry() {
        let mut shape = base_shape(SvgShapeKind::Rect);
        shape.x = 0.0;
        shape.y = 0.0;
        shape.width = 20.0;
        shape.height = 40.0;
        shape.rx = 4.0;
        shape.fill = "red".to_string();
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        // geometry + fill
        assert_eq!(out.len(), 2);
        match &out[0] {
            LottieShapeItem::Geometry(g) => {
                assert_eq!(g.kind, LottieShapeKind::Rect);
                assert_eq!(g.rect_position, [10.0, 20.0]);
                assert_eq!(g.rect_size, [20.0, 40.0]);
                assert_eq!(g.rect_roundness, 4.0);
            }
            _ => panic!("expected geometry"),
        }
    }

    #[test]
    fn ellipse_geometry() {
        let mut shape = base_shape(SvgShapeKind::Ellipse);
        shape.cx = 5.0;
        shape.cy = 7.0;
        shape.rx = 3.0;
        shape.ry = 2.0;
        shape.fill = "black".to_string();
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        match &out[0] {
            LottieShapeItem::Geometry(g) => {
                assert_eq!(g.kind, LottieShapeKind::Ellipse);
                assert_eq!(g.ellipse_position, [5.0, 7.0]);
                assert_eq!(g.ellipse_size, [6.0, 4.0]);
            }
            _ => panic!("expected geometry"),
        }
    }

    #[test]
    fn path_geometry_from_d() {
        let mut shape = base_shape(SvgShapeKind::Path);
        shape.d = Some("M0 0 L10 0 L10 10 Z".to_string());
        shape.fill = "black".to_string();
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        // 1 geom + 1 fill
        assert_eq!(out.len(), 2);
        match &out[0] {
            LottieShapeItem::Geometry(g) => {
                assert_eq!(g.kind, LottieShapeKind::Path);
                assert!(g.closed);
                assert!(!g.vertices.is_empty());
            }
            _ => panic!("expected geometry"),
        }
    }

    #[test]
    fn stroke_with_width_emitted() {
        let mut shape = base_shape(SvgShapeKind::Rect);
        shape.width = 10.0;
        shape.height = 10.0;
        shape.fill = "none".to_string();
        shape.stroke = Some("#00ff00".to_string());
        shape.stroke_width = 2.5;
        shape.stroke_linecap = Some("round".to_string());
        shape.stroke_linejoin = Some("bevel".to_string());
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        let stroke = out
            .iter()
            .find_map(|i| if let LottieShapeItem::Stroke(s) = i { Some(s) } else { None })
            .expect("stroke item");
        assert!((stroke.width - 2.5).abs() < 1e-9);
        assert_eq!(stroke.line_cap, 2);
        assert_eq!(stroke.line_join, 3);
        assert!((stroke.color[1] - 1.0).abs() < 1e-9);
    }

    #[test]
    fn dash_offset_becomes_trim_path() {
        let mut shape = base_shape(SvgShapeKind::Path);
        shape.d = Some("M0 0 L100 0".to_string());
        shape.fill = "none".to_string();
        shape.stroke = Some("#000".to_string());
        shape.stroke_width = 1.0;
        shape.stroke_dasharray = Some("100".to_string());
        shape.common.animations.push(SvgAnimationNode::Animate {
            attribute_name: "stroke-dashoffset".to_string(),
            common: SvgAnimationCommon {
                dur_seconds: 1.0,
                repeat_indefinite: false,
                additive: SvgAnimationAdditive::Replace,
                keyframes: SvgKeyframes {
                    key_times: vec![0.0, 1.0],
                    values: vec!["100".to_string(), "0".to_string()],
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: vec![],
                },
                delay_seconds: 0.0,
                direction: Default::default(),
                fill_mode: Default::default(),
            },
        });
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        let trim = out
            .iter()
            .find_map(|i| {
                if let LottieShapeItem::TrimPath(t) = i {
                    Some(t)
                } else {
                    None
                }
            })
            .expect("trim");
        if let LottieScalarProp::Animated { keyframes } = &trim.end {
            assert_eq!(keyframes.len(), 2);
            // At t=0, offset=100 ⇒ end% = (1 - 100/100)*100 = 0.
            assert!((keyframes[0].start - 0.0).abs() < 1e-9);
            // At t=1, offset=0 ⇒ end% = 100.
            assert!((keyframes[1].start - 100.0).abs() < 1e-9);
        } else {
            panic!("expected animated end");
        }
    }

    #[test]
    fn gradient_fill_from_defs() {
        let mut shape = base_shape(SvgShapeKind::Rect);
        shape.width = 10.0;
        shape.height = 10.0;
        shape.fill = "url(#g1)".to_string();
        let mut defs = SvgDefs::default();
        defs.gradients.insert(
            "g1".to_string(),
            SvgGradient {
                id: "g1".to_string(),
                kind: SvgGradientKind::Linear,
                stops: vec![
                    SvgStop {
                        offset: 0.0,
                        color: "#ff0000".to_string(),
                        stop_opacity: 1.0,
                        animations: vec![],
                    },
                    SvgStop {
                        offset: 1.0,
                        color: "#0000ff".to_string(),
                        stop_opacity: 1.0,
                        animations: vec![],
                    },
                ],
                units: SvgGradientUnits::ObjectBoundingBox,
                x1: 0.0,
                y1: 0.0,
                x2: 1.0,
                y2: 0.0,
                cx: 0.5,
                cy: 0.5,
                r: 0.5,
                fx: None,
                fy: None,
                has_gradient_transform: false,
                gradient_transform: None,
            },
        );
        let mut logs = mk_logs();
        let out = map(&shape, &defs, &mut logs);
        let gf = out
            .iter()
            .find_map(|i| {
                if let LottieShapeItem::GradientFill(g) = i {
                    Some(g)
                } else {
                    None
                }
            })
            .expect("gradient fill");
        assert_eq!(gf.color_stop_count, 2);
        assert_eq!(gf.kind, LottieGradientKind::Linear);
        // objectBoundingBox → mapped to rect [0..10].
        assert_eq!(gf.start_point, [0.0, 0.0]);
        assert_eq!(gf.end_point, [10.0, 0.0]);
        match &gf.stops {
            LottieGradientStops::Static { values } => {
                // 2 stops × 4 = 8 floats (no alpha part since stop_opacity==1).
                assert_eq!(values.len(), 8);
                assert_eq!(values[0], 0.0); // offset
                assert_eq!(values[1], 1.0); // r
            }
            _ => panic!("expected static stops"),
        }
    }

    #[test]
    fn fill_none_on_non_rect_still_emits_geometry_no_fill() {
        // Path with fill=none produces only geometry (no fill item).
        let mut shape = base_shape(SvgShapeKind::Path);
        shape.d = Some("M0 0 L5 5".to_string());
        shape.fill = "none".to_string();
        let mut logs = mk_logs();
        let out = map(&shape, &SvgDefs::default(), &mut logs);
        assert_eq!(out.len(), 1);
        assert!(matches!(out[0], LottieShapeItem::Geometry(_)));
    }

    #[test]
    fn hsl_color_round_trip_red() {
        let mut logs = mk_logs();
        let c = parse_color("hsl(0, 100%, 50%)", &mut logs).unwrap();
        assert!((c[0] - 1.0).abs() < 1e-9);
        assert!(c[1].abs() < 1e-9);
        assert!(c[2].abs() < 1e-9);
    }
}
