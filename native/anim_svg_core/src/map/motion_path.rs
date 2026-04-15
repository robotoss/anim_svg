//! Port of `lib/src/data/mappers/motion_path_resolver.dart`.
//!
//! Resolves CSS Motion Path declarations (`offset-path` + an animated
//! `offset-distance` track) into plain `SvgAnimateTransform` channels
//! (translate, and optionally rotate when `offset-rotate: auto|reverse`).
//!
//! The CSS parser emits an `SvgAnimate(attributeName: "offset-distance")`
//! placeholder because it cannot see the node it belongs to. This
//! resolver walks the document, finds each placeholder, and rewrites it
//! using the node's `motion_path` to sample `(x, y, tangent)` tuples
//! along the path.
//!
//! Sampling algorithm (ported directly from the Dart source, 32
//! sub-segments per cubic):
//! - Flatten every cubic contour into a polyline with tangents.
//! - Build a cumulative-length table; locate distance via binary search.
//! - Tangent at a sample uses the analytic derivative of the bezier.

use crate::domain::{
    SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode, SvgDefs,
    SvgDocument, SvgGroup, SvgImage, SvgKeyframes, SvgMotionPath, SvgMotionRotateKind, SvgNode,
    SvgShape, SvgTransformKind, SvgUse,
};
use crate::log::LogCollector;
use crate::parse::path_data;

/// Linear sub-divisions per cubic bezier segment used for length
/// estimation and sampling. 32 keeps per-point error well under 0.5px
/// for paths up to a few hundred pixels long.
pub const DEFAULT_SAMPLES_PER_SEGMENT: usize = 32;

/// Walks `doc`, rewriting every `offset-distance` placeholder into the
/// translate (+ optional rotate) tracks dictated by the node's
/// `motion_path`. Nodes without a motion path but with an orphan
/// `offset-distance` track have the track stripped.
pub fn resolve(doc: SvgDocument, logs: &mut LogCollector) -> SvgDocument {
    resolve_with_samples(doc, DEFAULT_SAMPLES_PER_SEGMENT, logs)
}

/// Same as [`resolve`] but lets callers tune the flattening density.
pub fn resolve_with_samples(
    doc: SvgDocument,
    samples_per_segment: usize,
    logs: &mut LogCollector,
) -> SvgDocument {
    let root = resolve_group(doc.root, samples_per_segment, logs);
    let mut defs = doc.defs;
    let resolved_by_id = std::mem::take(&mut defs.by_id)
        .into_iter()
        .map(|(k, v)| (k, resolve_node(v, samples_per_segment, logs)))
        .collect();
    defs.by_id = resolved_by_id;
    SvgDocument {
        width: doc.width,
        height: doc.height,
        view_box: doc.view_box,
        defs,
        root,
    }
}

fn resolve_group(mut g: SvgGroup, samples: usize, logs: &mut LogCollector) -> SvgGroup {
    let new_children: Vec<SvgNode> = std::mem::take(&mut g.children)
        .into_iter()
        .map(|c| resolve_node(c, samples, logs))
        .collect();
    g.children = new_children;
    rewrite_animations_on_common(&mut g.common, samples, logs);
    g
}

fn resolve_node(n: SvgNode, samples: usize, logs: &mut LogCollector) -> SvgNode {
    match n {
        SvgNode::Group(g) => SvgNode::Group(resolve_group(g, samples, logs)),
        SvgNode::Shape(mut s) => {
            rewrite_animations_on_common(&mut s.common, samples, logs);
            SvgNode::Shape(s)
        }
        SvgNode::Image(mut i) => {
            rewrite_animations_on_common(&mut i.common, samples, logs);
            SvgNode::Image(i)
        }
        SvgNode::Use(mut u) => {
            rewrite_animations_on_common(&mut u.common, samples, logs);
            SvgNode::Use(u)
        }
    }
}

fn rewrite_animations_on_common(
    common: &mut crate::domain::SvgNodeCommon,
    samples: usize,
    logs: &mut LogCollector,
) {
    let has_offset = common.animations.iter().any(|a| matches!(
        a,
        SvgAnimationNode::Animate { attribute_name, .. } if attribute_name == "offset-distance"
    ));
    if !has_offset {
        return;
    }
    let id = common.id.clone().unwrap_or_default();
    match &common.motion_path {
        None => {
            logs.warn(
                "map.motion_path",
                "offset-distance animation without offset-path — dropping track",
                &[("id", id.into())],
            );
            common.animations.retain(|a| !is_offset_distance(a));
        }
        Some(mp) => {
            let mp = mp.clone();
            match PathSampler::build(&mp.path_data, samples, logs) {
                None => {
                    common.animations.retain(|a| !is_offset_distance(a));
                }
                Some(sampler) => {
                    let old = std::mem::take(&mut common.animations);
                    let mut out: Vec<SvgAnimationNode> = Vec::with_capacity(old.len() + 1);
                    for a in old {
                        if is_offset_distance(&a) {
                            if let SvgAnimationNode::Animate { common: anim, .. } = a {
                                out.extend(expand(&anim, &mp, &sampler, logs));
                            }
                        } else {
                            out.push(a);
                        }
                    }
                    common.animations = out;
                }
            }
        }
    }
}

fn is_offset_distance(a: &SvgAnimationNode) -> bool {
    matches!(
        a,
        SvgAnimationNode::Animate { attribute_name, .. } if attribute_name == "offset-distance"
    )
}

/// Public expansion of a single offset-distance animation against the
/// given motion path. Exposed primarily for tests and for callers that
/// already located the pair.
pub fn expand(
    anim: &SvgAnimationCommon,
    mp: &SvgMotionPath,
    sampler: &PathSampler,
    logs: &mut LogCollector,
) -> Vec<SvgAnimationNode> {
    let emit_rotate = mp.rotate.kind != SvgMotionRotateKind::Fixed;
    let mut translates: Vec<String> = Vec::with_capacity(anim.keyframes.values.len());
    let mut rotates: Vec<String> = Vec::with_capacity(anim.keyframes.values.len());
    for raw in &anim.keyframes.values {
        let pct = parse_percent(raw);
        let clamped = pct.clamp(0.0, 1.0);
        if !(0.0..=1.0).contains(&pct) {
            logs.warn(
                "map.motion_path",
                "offset-distance out of [0%,100%] — clamped",
                &[("raw", raw.clone().into())],
            );
        }
        let sample = sampler.sample_at(clamped);
        translates.push(format!("{},{}", fmt(sample.x), fmt(sample.y)));
        if emit_rotate {
            let mut deg = sample.tangent_deg;
            if mp.rotate.kind == SvgMotionRotateKind::Reverse {
                deg += 180.0;
            }
            rotates.push(fmt(deg));
        }
    }

    let mut out: Vec<SvgAnimationNode> = Vec::with_capacity(2);
    out.push(SvgAnimationNode::AnimateTransform {
        kind: SvgTransformKind::Translate,
        common: SvgAnimationCommon {
            dur_seconds: anim.dur_seconds,
            repeat_indefinite: anim.repeat_indefinite,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times: anim.keyframes.key_times.clone(),
                values: translates,
                calc_mode: anim.keyframes.calc_mode,
                key_splines: anim.keyframes.key_splines.clone(),
            },
            delay_seconds: anim.delay_seconds,
            direction: anim.direction,
            fill_mode: anim.fill_mode,
        },
    });

    if emit_rotate {
        out.push(SvgAnimationNode::AnimateTransform {
            kind: SvgTransformKind::Rotate,
            common: SvgAnimationCommon {
                dur_seconds: anim.dur_seconds,
                repeat_indefinite: anim.repeat_indefinite,
                additive: SvgAnimationAdditive::Sum,
                keyframes: SvgKeyframes {
                    key_times: anim.keyframes.key_times.clone(),
                    values: rotates,
                    calc_mode: anim.keyframes.calc_mode,
                    key_splines: anim.keyframes.key_splines.clone(),
                },
                delay_seconds: anim.delay_seconds,
                direction: anim.direction,
                fill_mode: anim.fill_mode,
            },
        });
    } else if mp.rotate.angle_deg != 0.0 {
        // Static rotate: emit a 2-frame identical track so the angle
        // applies even when other channels are absent. Keeps downstream
        // `values.len() >= 2` invariants intact.
        let deg = fmt(mp.rotate.angle_deg);
        out.push(SvgAnimationNode::AnimateTransform {
            kind: SvgTransformKind::Rotate,
            common: SvgAnimationCommon {
                dur_seconds: anim.dur_seconds,
                repeat_indefinite: anim.repeat_indefinite,
                additive: SvgAnimationAdditive::Sum,
                keyframes: SvgKeyframes {
                    key_times: vec![0.0, 1.0],
                    values: vec![deg.clone(), deg],
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: Vec::new(),
                },
                delay_seconds: anim.delay_seconds,
                direction: anim.direction,
                fill_mode: anim.fill_mode,
            },
        });
    }
    out
}

fn parse_percent(raw: &str) -> f64 {
    let t = raw.trim();
    if let Some(stripped) = t.strip_suffix('%') {
        return stripped.trim().parse::<f64>().unwrap_or(0.0) / 100.0;
    }
    t.parse::<f64>().unwrap_or(0.0)
}

fn fmt(v: f64) -> String {
    if !v.is_finite() {
        return "0".to_string();
    }
    if v == v.trunc() {
        return format!("{:.0}", v);
    }
    // Round to 4 decimals, strip trailing zeros.
    let rounded = format!("{:.4}", v).parse::<f64>().unwrap_or(v);
    // f64::to_string prints shortest round-trippable repr.
    rounded.to_string()
}

/// One sampled point along the flattened motion path.
#[derive(Debug, Clone, Copy)]
pub struct PathSample {
    pub x: f64,
    pub y: f64,
    pub tangent_deg: f64,
}

/// Precomputed (x, y, tangent) samples along a flattened cubic path.
/// Built once per node and reused for every keyframe in the
/// `offset-distance` animation.
pub struct PathSampler {
    points: Vec<PathSample>,
    cumulative_lens: Vec<f64>,
    total_len: f64,
}

impl PathSampler {
    /// Parses and flattens `path_data`. Returns `None` when the path
    /// yields zero contours.
    pub fn build(
        path_data: &str,
        samples_per_segment: usize,
        logs: &mut LogCollector,
    ) -> Option<Self> {
        let contours = path_data::parse(path_data, true, logs);
        if contours.is_empty() {
            logs.warn(
                "map.motion_path",
                "offset-path parsed to zero contours",
                &[("d", path_data.to_string().into())],
            );
            return None;
        }

        let mut samples: Vec<PathSample> = Vec::new();
        let mut cumulative_lens: Vec<f64> = vec![0.0];
        let mut cumulative: f64 = 0.0;

        for contour in &contours {
            let n = contour.vertices.len();
            if n == 0 {
                continue;
            }
            let segment_end = if contour.closed { n } else { n.saturating_sub(1) };
            for i in 0..segment_end {
                let v0 = contour.vertices[i];
                let v1 = contour.vertices[(i + 1) % n];
                let out_t = contour.out_tangents[i];
                let in_t = contour.in_tangents[(i + 1) % n];
                let p0x = v0[0];
                let p0y = v0[1];
                let p1x = p0x + out_t[0];
                let p1y = p0y + out_t[1];
                let p2x = v1[0] + in_t[0];
                let p2y = v1[1] + in_t[1];
                let p3x = v1[0];
                let p3y = v1[1];
                let mut prev_x = p0x;
                let mut prev_y = p0y;
                for s in 1..=samples_per_segment {
                    let t = s as f64 / samples_per_segment as f64;
                    let omt = 1.0 - t;
                    let bx = omt * omt * omt * p0x
                        + 3.0 * omt * omt * t * p1x
                        + 3.0 * omt * t * t * p2x
                        + t * t * t * p3x;
                    let by = omt * omt * omt * p0y
                        + 3.0 * omt * omt * t * p1y
                        + 3.0 * omt * t * t * p2y
                        + t * t * t * p3y;
                    let mut dx = 3.0 * omt * omt * (p1x - p0x)
                        + 6.0 * omt * t * (p2x - p1x)
                        + 3.0 * t * t * (p3x - p2x);
                    let mut dy = 3.0 * omt * omt * (p1y - p0y)
                        + 6.0 * omt * t * (p2y - p1y)
                        + 3.0 * t * t * (p3y - p2y);
                    // Degenerate-cubic fallback for straight-line
                    // segments (both tangents zero): the derivative
                    // vanishes at t=0 and t=1. Fall back to the chord.
                    if dx * dx + dy * dy < 1e-12 {
                        dx = p3x - p0x;
                        dy = p3y - p0y;
                    }
                    let seg_len = ((bx - prev_x) * (bx - prev_x)
                        + (by - prev_y) * (by - prev_y))
                        .sqrt();
                    cumulative += seg_len;
                    cumulative_lens.push(cumulative);
                    let angle = if dx == 0.0 && dy == 0.0 {
                        0.0
                    } else {
                        dy.atan2(dx).to_degrees()
                    };
                    samples.push(PathSample {
                        x: bx,
                        y: by,
                        tangent_deg: angle,
                    });
                    prev_x = bx;
                    prev_y = by;
                }
            }
        }

        if samples.is_empty() {
            // Path had only moveTo — no length to animate along. Emit a
            // single sample at the start so keyframes collapse to a
            // static position.
            let first = contours[0].vertices[0];
            samples.push(PathSample {
                x: first[0],
                y: first[1],
                tangent_deg: 0.0,
            });
            cumulative_lens.push(0.0);
            logs.warn(
                "map.motion_path",
                "offset-path has zero length — static fallback",
                &[("d", path_data.to_string().into())],
            );
        }

        // Prepend the starting vertex itself as sample[-1]
        // (cumulative_lens[0] already equals 0.0).
        let start = contours[0].vertices[0];
        let start_angle = samples[0].tangent_deg;
        let mut all: Vec<PathSample> = Vec::with_capacity(samples.len() + 1);
        all.push(PathSample {
            x: start[0],
            y: start[1],
            tangent_deg: start_angle,
        });
        all.extend(samples);

        let total_len = if cumulative == 0.0 { 0.0 } else { cumulative };
        Some(PathSampler {
            points: all,
            cumulative_lens,
            total_len,
        })
    }

    pub fn total_len(&self) -> f64 {
        self.total_len
    }

    pub fn sample_at(&self, pct: f64) -> PathSample {
        if self.total_len == 0.0 {
            return self.points[0];
        }
        let target = pct * self.total_len;
        let lens = &self.cumulative_lens;
        // Binary search for the interval containing `target`.
        let mut lo: usize = 0;
        let mut hi: usize = lens.len() - 1;
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1;
            if lens[mid] <= target {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        let a = self.points[lo];
        let b = self.points[hi];
        let seg_len = lens[hi] - lens[lo];
        let f = if seg_len == 0.0 {
            0.0
        } else {
            (target - lens[lo]) / seg_len
        };
        let x = a.x + (b.x - a.x) * f;
        let y = a.y + (b.y - a.y) * f;
        // Tangent: snap to the segment endpoint's tangent — already the
        // derivative at that bezier-t. Lerping two atan2 values wraps
        // badly at ±180°. Good enough for the 32-subseg flattening.
        let tangent = if f < 0.5 { a.tangent_deg } else { b.tangent_deg };
        PathSample {
            x,
            y,
            tangent_deg: tangent,
        }
    }
}

// --- helpers so the tree walker signature stays generic -------------------

#[allow(dead_code)]
fn touch_types(_g: SvgGroup, _s: SvgShape, _i: SvgImage, _u: SvgUse, _d: SvgDefs) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{SvgMotionRotate, SvgMotionRotateKind};
    use crate::log::LogLevel;

    fn logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn common_two(values: Vec<&str>) -> SvgAnimationCommon {
        SvgAnimationCommon {
            dur_seconds: 1.0,
            repeat_indefinite: false,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times: (0..values.len())
                    .map(|i| i as f64 / (values.len() - 1).max(1) as f64)
                    .collect(),
                values: values.into_iter().map(|s| s.to_string()).collect(),
                calc_mode: SvgAnimationCalcMode::Linear,
                key_splines: Vec::new(),
            },
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        }
    }

    #[test]
    fn straight_line_samples_monotonically() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();
        let s0 = sampler.sample_at(0.0);
        let s50 = sampler.sample_at(0.5);
        let s100 = sampler.sample_at(1.0);
        assert!((s0.x - 0.0).abs() < 1e-6);
        assert!((s50.x - 50.0).abs() < 1e-6);
        assert!((s100.x - 100.0).abs() < 1e-6);
        // y stays on the line.
        assert!(s0.y.abs() < 1e-6);
        assert!(s50.y.abs() < 1e-6);
        assert!(s100.y.abs() < 1e-6);
        // Monotonic x.
        let mut prev = f64::NEG_INFINITY;
        for i in 0..=20 {
            let s = sampler.sample_at(i as f64 / 20.0);
            assert!(s.x >= prev - 1e-9, "x regressed: {} < {}", s.x, prev);
            prev = s.x;
        }
    }

    #[test]
    fn curve_produces_many_keyframes() {
        // One cubic segment, 32 sub-segments → expect 32 interior
        // samples plus the start vertex = 33 points.
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 C50 0 50 100 100 100", 32, &mut l).unwrap();
        assert!(sampler.points.len() >= 32, "got only {} points", sampler.points.len());
        assert!(sampler.total_len > 100.0);
    }

    #[test]
    fn rotate_auto_aligns_with_tangent_on_straight_line() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();
        // Expand with rotate=auto → rotation angles should be ~0°
        // everywhere (tangent pointing +x).
        let anim = common_two(vec!["0%", "100%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L100 0".to_string(),
            rotate: SvgMotionRotate::AUTO,
        };
        let out = expand(&anim, &mp, &sampler, &mut l);
        assert_eq!(out.len(), 2);
        let rot = match &out[1] {
            SvgAnimationNode::AnimateTransform { kind, common } => {
                assert_eq!(*kind, SvgTransformKind::Rotate);
                common
            }
            _ => panic!("expected rotate track"),
        };
        for v in &rot.keyframes.values {
            let parsed: f64 = v.parse().unwrap();
            assert!(parsed.abs() < 1e-3, "expected ~0°, got {}", parsed);
        }
    }

    #[test]
    fn rotate_auto_on_vertical_line_is_90_degrees() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L0 100", 32, &mut l).unwrap();
        let anim = common_two(vec!["0%", "100%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L0 100".to_string(),
            rotate: SvgMotionRotate::AUTO,
        };
        let out = expand(&anim, &mp, &sampler, &mut l);
        let rot = match &out[1] {
            SvgAnimationNode::AnimateTransform { common, .. } => common,
            _ => panic!(),
        };
        let last: f64 = rot.keyframes.values.last().unwrap().parse().unwrap();
        assert!((last - 90.0).abs() < 1e-3, "expected 90°, got {}", last);
    }

    #[test]
    fn offset_distance_percent_and_bare_number_parse() {
        // "25%" and "0.25" are equivalent along a 100-unit path (→ x=25).
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();

        let anim_pct = common_two(vec!["0%", "25%", "100%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L100 0".to_string(),
            rotate: SvgMotionRotate::fixed(0.0),
        };
        let out_pct = expand(&anim_pct, &mp, &sampler, &mut l);
        let t_pct = match &out_pct[0] {
            SvgAnimationNode::AnimateTransform { common, .. } => common,
            _ => panic!(),
        };
        // Middle keyframe = "25,0"
        assert_eq!(t_pct.keyframes.values[1], "25,0");

        let anim_bare = common_two(vec!["0", "0.25", "1"]);
        let out_bare = expand(&anim_bare, &mp, &sampler, &mut l);
        let t_bare = match &out_bare[0] {
            SvgAnimationNode::AnimateTransform { common, .. } => common,
            _ => panic!(),
        };
        assert_eq!(t_bare.keyframes.values[1], "25,0");
    }

    #[test]
    fn rotate_reverse_adds_180() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();
        let anim = common_two(vec!["0%", "100%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L100 0".to_string(),
            rotate: SvgMotionRotate::REVERSE,
        };
        let out = expand(&anim, &mp, &sampler, &mut l);
        let rot = match &out[1] {
            SvgAnimationNode::AnimateTransform { common, .. } => common,
            _ => panic!(),
        };
        let first: f64 = rot.keyframes.values[0].parse().unwrap();
        assert!((first - 180.0).abs() < 1e-3, "expected 180°, got {}", first);
    }

    #[test]
    fn rotate_fixed_emits_static_track_when_nonzero() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();
        let anim = common_two(vec!["0%", "100%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L100 0".to_string(),
            rotate: SvgMotionRotate::fixed(45.0),
        };
        let out = expand(&anim, &mp, &sampler, &mut l);
        // translate + static rotate.
        assert_eq!(out.len(), 2);
        let rot = match &out[1] {
            SvgAnimationNode::AnimateTransform { kind, common } => {
                assert_eq!(*kind, SvgTransformKind::Rotate);
                common
            }
            _ => panic!(),
        };
        assert_eq!(rot.keyframes.values, vec!["45", "45"]);
    }

    #[test]
    fn rotate_fixed_zero_emits_only_translate() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();
        let anim = common_two(vec!["0%", "100%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L100 0".to_string(),
            rotate: SvgMotionRotate::fixed(0.0),
        };
        let out = expand(&anim, &mp, &sampler, &mut l);
        assert_eq!(out.len(), 1);
        matches!(&out[0], SvgAnimationNode::AnimateTransform { kind: SvgTransformKind::Translate, .. });
    }

    #[test]
    fn out_of_range_offset_distance_is_clamped_and_logged() {
        let mut l = logs();
        let sampler = PathSampler::build("M0 0 L100 0", 32, &mut l).unwrap();
        let anim = common_two(vec!["-10%", "110%"]);
        let mp = SvgMotionPath {
            path_data: "M0 0 L100 0".to_string(),
            rotate: SvgMotionRotate::fixed(0.0),
        };
        let out = expand(&anim, &mp, &sampler, &mut l);
        let t = match &out[0] {
            SvgAnimationNode::AnimateTransform { common, .. } => common,
            _ => panic!(),
        };
        // Clamped → 0 and 100 along path.
        assert_eq!(t.keyframes.values[0], "0,0");
        assert_eq!(t.keyframes.values[1], "100,0");
    }

    #[test]
    fn resolve_drops_orphan_offset_distance() {
        let mut l = logs();
        let anim = common_two(vec!["0%", "100%"]);
        let shape = SvgShape {
            common: crate::domain::SvgNodeCommon {
                id: Some("n".into()),
                animations: vec![SvgAnimationNode::Animate {
                    attribute_name: "offset-distance".into(),
                    common: anim,
                }],
                motion_path: None,
                ..Default::default()
            },
            ..Default::default()
        };
        let doc = SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: crate::domain::SvgViewBox {
                x: 0.0,
                y: 0.0,
                w: 100.0,
                h: 100.0,
            },
            defs: SvgDefs::default(),
            root: SvgGroup {
                common: Default::default(),
                children: vec![SvgNode::Shape(shape)],
                display_none: false,
            },
        };
        let out = resolve(doc, &mut l);
        let child = &out.root.children[0];
        assert!(child.common().animations.is_empty());
    }

    #[test]
    fn resolve_expands_on_node_with_motion_path() {
        let mut l = logs();
        let anim = common_two(vec!["0%", "100%"]);
        let shape = SvgShape {
            common: crate::domain::SvgNodeCommon {
                id: Some("n".into()),
                animations: vec![SvgAnimationNode::Animate {
                    attribute_name: "offset-distance".into(),
                    common: anim,
                }],
                motion_path: Some(SvgMotionPath {
                    path_data: "M0 0 L100 0".to_string(),
                    rotate: SvgMotionRotate {
                        kind: SvgMotionRotateKind::Auto,
                        angle_deg: 0.0,
                    },
                }),
                ..Default::default()
            },
            ..Default::default()
        };
        let doc = SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: crate::domain::SvgViewBox {
                x: 0.0,
                y: 0.0,
                w: 100.0,
                h: 100.0,
            },
            defs: SvgDefs::default(),
            root: SvgGroup {
                common: Default::default(),
                children: vec![SvgNode::Shape(shape)],
                display_none: false,
            },
        };
        let out = resolve(doc, &mut l);
        let child = &out.root.children[0];
        // translate + rotate.
        assert_eq!(child.common().animations.len(), 2);
        match &child.common().animations[0] {
            SvgAnimationNode::AnimateTransform { kind, .. } => {
                assert_eq!(*kind, SvgTransformKind::Translate);
            }
            _ => panic!("expected translate"),
        }
        match &child.common().animations[1] {
            SvgAnimationNode::AnimateTransform { kind, .. } => {
                assert_eq!(*kind, SvgTransformKind::Rotate);
            }
            _ => panic!("expected rotate"),
        }
    }
}
