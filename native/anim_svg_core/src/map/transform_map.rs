//! Port of `lib/src/data/mappers/transform_mapper.dart`.
//!
//! Converts a list of `<animateTransform>` nodes into Lottie transform
//! properties.
//!
//! SMIL emits "scale around pivot" as a chain of animateTransforms on a
//! single element:
//!
//! ```text
//! additive="replace" type="translate" values="px,py;..."     → ks.p (position)
//! additive="sum"     type="scale"     values="sx,sy;..."     → ks.s (scale)
//! additive="sum"     type="rotate"    values="deg,0,0;..."   → ks.r (rotation)
//! additive="sum"     type="translate" values="-ax,-ay;..."   → ks.a (anchor, sign-flipped)
//! ```
//!
//! The last line is SVG's way of shifting the pivot: the inner translate
//! is applied before scale/rotate, so the transformed point is
//! `p + R·s·(P + pivot)`. Setting Lottie anchor to `-pivot` reproduces
//! that exactly, since Lottie computes `p + R·s·(P - a)`.

use crate::domain::{
    LottieScalarKeyframe, LottieScalarProp, LottieVectorKeyframe, LottieVectorProp,
    SvgAnimationAdditive, SvgAnimationCommon, SvgAnimationNode, SvgTransformKind,
};
use crate::log::LogCollector;
use crate::map::keyspline;

/// Mirrors Dart `AnimatedTransform`. A partial Lottie transform — only
/// fields with a matching `<animateTransform>` are populated. Callers
/// merge this into `LottieTransform` defaults.
#[derive(Debug, Clone, Default)]
pub struct AnimatedTransform {
    pub position: Option<LottieVectorProp>,
    pub scale: Option<LottieVectorProp>,
    pub rotation: Option<LottieScalarProp>,
    /// Pivot encoded as Lottie anchor (sign-flipped from the SMIL inner
    /// `additive="sum"` translate).
    pub anchor: Option<LottieVectorProp>,
}

pub const DEFAULT_FRAME_RATE: f64 = 60.0;

/// Maps a list of animateTransform nodes to Lottie transform props.
///
/// Only `SvgAnimationNode::AnimateTransform` variants are considered;
/// plain `<animate>` nodes are ignored. Duplicate kinds (other than the
/// translate replace/sum split) are logged and dropped.
pub fn map_transforms(
    animations: &[SvgAnimationNode],
    frame_rate: f64,
    logs: &mut LogCollector,
) -> AnimatedTransform {
    let mut result = AnimatedTransform::default();

    // Bucket animations by (kind, role). For translate we distinguish
    // replace (→ position) from sum (→ anchor); scale/rotate collapse
    // into one slot each.
    let mut position_anim: Option<&SvgAnimationCommon> = None;
    let mut anchor_anim: Option<&SvgAnimationCommon> = None;
    let mut scale_anim: Option<&SvgAnimationCommon> = None;
    let mut rotate_anim: Option<&SvgAnimationCommon> = None;

    for node in animations {
        let (kind, common) = match node {
            SvgAnimationNode::AnimateTransform { kind, common } => (*kind, common),
            _ => continue,
        };
        match kind {
            SvgTransformKind::Translate => {
                if common.additive == SvgAnimationAdditive::Replace {
                    if position_anim.is_some() {
                        logs.warn(
                            "map.transform",
                            "duplicate replace-translate; keeping first",
                            &[],
                        );
                        continue;
                    }
                    position_anim = Some(common);
                } else {
                    if anchor_anim.is_some() {
                        logs.warn(
                            "map.transform",
                            "duplicate sum-translate; keeping first",
                            &[],
                        );
                        continue;
                    }
                    anchor_anim = Some(common);
                }
            }
            SvgTransformKind::Scale => {
                if scale_anim.is_some() {
                    logs.warn("map.transform", "duplicate scale anim; keeping first", &[]);
                    continue;
                }
                scale_anim = Some(common);
            }
            SvgTransformKind::Rotate => {
                if rotate_anim.is_some() {
                    logs.warn("map.transform", "duplicate rotate anim; keeping first", &[]);
                    continue;
                }
                rotate_anim = Some(common);
            }
            SvgTransformKind::SkewX | SvgTransformKind::SkewY | SvgTransformKind::Matrix => {
                logs.warn(
                    "map.transform",
                    "skipping skew/matrix animateTransform",
                    &[("kind", format!("{:?}", kind).into())],
                );
            }
        }
    }

    if let Some(p) = position_anim {
        result.position = Some(vector_keyframes(p, 2, 1.0, frame_rate, logs));
    }
    if let Some(s) = scale_anim {
        result.scale = Some(vector_keyframes(s, 2, 100.0, frame_rate, logs));
    }
    if let Some(r) = rotate_anim {
        // rotate values may be "deg" or "deg cx cy"; we keep degrees
        // only. Pivot compensation in SMIL is handled by the
        // additive="sum" translate path → anchor.
        result.rotation = Some(scalar_keyframes(r, frame_rate, logs));
    }
    if let Some(a) = anchor_anim {
        // Sign-flip the pivot offset → Lottie anchor.
        result.anchor = Some(vector_keyframes(a, 2, -1.0, frame_rate, logs));
    }

    result
}

fn split_numbers(v: &str) -> Vec<f64> {
    v.split(|c: char| c == ' ' || c == ',')
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<f64>().ok())
        .collect()
}

fn vector_keyframes(
    anim: &SvgAnimationCommon,
    dims: usize,
    scale: f64,
    frame_rate: f64,
    logs: &mut LogCollector,
) -> LottieVectorProp {
    let mut parsed: Vec<Vec<f64>> = Vec::with_capacity(anim.keyframes.values.len());
    for v in &anim.keyframes.values {
        let nums = split_numbers(v);
        if nums.len() < dims {
            // uniform scale: scale="0.5" → [0.5, 0.5]
            let first = nums.first().copied().unwrap_or(0.0);
            parsed.push(vec![first * scale; dims]);
        } else {
            parsed.push(nums.into_iter().take(dims).map(|n| n * scale).collect());
        }
    }

    let mut keyframes: Vec<LottieVectorKeyframe> = Vec::with_capacity(parsed.len());
    for i in 0..parsed.len() {
        let frame = anim.keyframes.key_times[i] * anim.dur_seconds * frame_rate;
        let (bezier_in, bezier_out) = if i == 0 {
            let (out_h, _) = keyspline::segment(&anim.keyframes, 0, logs);
            (None, out_h)
        } else {
            let (_, in_h) = keyspline::segment(&anim.keyframes, i - 1, logs);
            let out_h = if i < parsed.len() - 1 {
                keyspline::segment(&anim.keyframes, i, logs).0
            } else {
                None
            };
            (in_h, out_h)
        };
        keyframes.push(LottieVectorKeyframe {
            time: frame,
            start: parsed[i].clone(),
            hold: keyspline::hold(&anim.keyframes),
            bezier_in,
            bezier_out,
        });
    }
    LottieVectorProp::Animated { keyframes }
}

fn scalar_keyframes(
    anim: &SvgAnimationCommon,
    frame_rate: f64,
    logs: &mut LogCollector,
) -> LottieScalarProp {
    let parsed: Vec<f64> = anim
        .keyframes
        .values
        .iter()
        .map(|v| split_numbers(v).first().copied().unwrap_or(0.0))
        .collect();

    let mut keyframes: Vec<LottieScalarKeyframe> = Vec::with_capacity(parsed.len());
    for i in 0..parsed.len() {
        let frame = anim.keyframes.key_times[i] * anim.dur_seconds * frame_rate;
        let (bezier_in, bezier_out) = if i == 0 {
            let (out_h, _) = keyspline::segment(&anim.keyframes, 0, logs);
            (None, out_h)
        } else {
            let (_, in_h) = keyspline::segment(&anim.keyframes, i - 1, logs);
            let out_h = if i < parsed.len() - 1 {
                keyspline::segment(&anim.keyframes, i, logs).0
            } else {
                None
            };
            (in_h, out_h)
        };
        keyframes.push(LottieScalarKeyframe {
            time: frame,
            start: parsed[i],
            hold: keyspline::hold(&anim.keyframes),
            bezier_in,
            bezier_out,
        });
    }
    LottieScalarProp::Animated { keyframes }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        SvgAnimationAdditive, SvgAnimationCalcMode, SvgKeyframes,
    };
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn anim_transform(
        kind: SvgTransformKind,
        additive: SvgAnimationAdditive,
        values: Vec<&str>,
        key_times: Vec<f64>,
        dur: f64,
    ) -> SvgAnimationNode {
        SvgAnimationNode::AnimateTransform {
            kind,
            common: SvgAnimationCommon {
                dur_seconds: dur,
                repeat_indefinite: false,
                additive,
                keyframes: SvgKeyframes {
                    key_times,
                    values: values.into_iter().map(String::from).collect(),
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: vec![],
                },
                delay_seconds: 0.0,
                direction: Default::default(),
                fill_mode: Default::default(),
            },
        }
    }

    #[test]
    fn translate_replace_becomes_position() {
        let mut logs = mk_logs();
        let anim = anim_transform(
            SvgTransformKind::Translate,
            SvgAnimationAdditive::Replace,
            vec!["0 0", "10 20"],
            vec![0.0, 1.0],
            1.0,
        );
        let t = map_transforms(&[anim], 60.0, &mut logs);
        let pos = t.position.expect("position set");
        match pos {
            LottieVectorProp::Animated { keyframes } => {
                assert_eq!(keyframes.len(), 2);
                assert_eq!(keyframes[0].start, vec![0.0, 0.0]);
                assert_eq!(keyframes[1].start, vec![10.0, 20.0]);
            }
            _ => panic!(),
        }
        assert!(t.anchor.is_none());
        assert!(t.scale.is_none());
        assert!(t.rotation.is_none());
    }

    #[test]
    fn scale_sum_scales_to_100_units() {
        let mut logs = mk_logs();
        let anim = anim_transform(
            SvgTransformKind::Scale,
            SvgAnimationAdditive::Sum,
            vec!["1 1", "2 0.5"],
            vec![0.0, 1.0],
            1.0,
        );
        let t = map_transforms(&[anim], 60.0, &mut logs);
        let s = t.scale.unwrap();
        if let LottieVectorProp::Animated { keyframes } = s {
            assert_eq!(keyframes[0].start, vec![100.0, 100.0]);
            assert_eq!(keyframes[1].start, vec![200.0, 50.0]);
        } else {
            panic!();
        }
    }

    #[test]
    fn uniform_scale_is_broadcast_to_two_dims() {
        let mut logs = mk_logs();
        let anim = anim_transform(
            SvgTransformKind::Scale,
            SvgAnimationAdditive::Sum,
            vec!["0.5", "2"],
            vec![0.0, 1.0],
            1.0,
        );
        let t = map_transforms(&[anim], 60.0, &mut logs);
        if let Some(LottieVectorProp::Animated { keyframes }) = t.scale {
            assert_eq!(keyframes[0].start, vec![50.0, 50.0]);
            assert_eq!(keyframes[1].start, vec![200.0, 200.0]);
        } else {
            panic!();
        }
    }

    #[test]
    fn rotate_keeps_only_degrees() {
        let mut logs = mk_logs();
        let anim = anim_transform(
            SvgTransformKind::Rotate,
            SvgAnimationAdditive::Sum,
            vec!["0 100 200", "90 100 200"],
            vec![0.0, 1.0],
            1.0,
        );
        let t = map_transforms(&[anim], 60.0, &mut logs);
        let r = t.rotation.unwrap();
        if let LottieScalarProp::Animated { keyframes } = r {
            assert_eq!(keyframes[0].start, 0.0);
            assert_eq!(keyframes[1].start, 90.0);
        } else {
            panic!();
        }
    }

    #[test]
    fn pivot_compensation_sign_flips_sum_translate_to_anchor() {
        let mut logs = mk_logs();
        // The inner additive="sum" translate carries `-ax,-ay`; we flip
        // the sign with the `scale = -1.0` path → anchor `ax, ay`.
        let anim = anim_transform(
            SvgTransformKind::Translate,
            SvgAnimationAdditive::Sum,
            vec!["-10 -20", "-30 -40"],
            vec![0.0, 1.0],
            1.0,
        );
        let t = map_transforms(&[anim], 60.0, &mut logs);
        let a = t.anchor.expect("anchor set");
        if let LottieVectorProp::Animated { keyframes } = a {
            assert_eq!(keyframes[0].start, vec![10.0, 20.0]);
            assert_eq!(keyframes[1].start, vec![30.0, 40.0]);
        } else {
            panic!();
        }
        assert!(t.position.is_none());
    }

    #[test]
    fn static_plus_animated_combined_full_chain() {
        // A complete SMIL "scale around pivot" chain: static-ish
        // (single-keyframe) replace-translate + animated sum-scale +
        // animated sum-rotate + static sum-translate (anchor).
        let mut logs = mk_logs();
        let animations = vec![
            anim_transform(
                SvgTransformKind::Translate,
                SvgAnimationAdditive::Replace,
                vec!["5 5", "5 5"],
                vec![0.0, 1.0],
                1.0,
            ),
            anim_transform(
                SvgTransformKind::Scale,
                SvgAnimationAdditive::Sum,
                vec!["1", "2"],
                vec![0.0, 1.0],
                1.0,
            ),
            anim_transform(
                SvgTransformKind::Rotate,
                SvgAnimationAdditive::Sum,
                vec!["0 0 0", "180 0 0"],
                vec![0.0, 1.0],
                1.0,
            ),
            anim_transform(
                SvgTransformKind::Translate,
                SvgAnimationAdditive::Sum,
                vec!["-3 -4", "-3 -4"],
                vec![0.0, 1.0],
                1.0,
            ),
        ];
        let t = map_transforms(&animations, 60.0, &mut logs);
        assert!(t.position.is_some());
        assert!(t.scale.is_some());
        assert!(t.rotation.is_some());
        let a = t.anchor.expect("anchor");
        if let LottieVectorProp::Animated { keyframes } = a {
            assert_eq!(keyframes[0].start, vec![3.0, 4.0]);
        } else {
            panic!();
        }
    }

    #[test]
    fn duplicate_rotate_is_dropped() {
        let mut logs = mk_logs();
        let animations = vec![
            anim_transform(
                SvgTransformKind::Rotate,
                SvgAnimationAdditive::Sum,
                vec!["0", "90"],
                vec![0.0, 1.0],
                1.0,
            ),
            anim_transform(
                SvgTransformKind::Rotate,
                SvgAnimationAdditive::Sum,
                vec!["0", "180"],
                vec![0.0, 1.0],
                1.0,
            ),
        ];
        let t = map_transforms(&animations, 60.0, &mut logs);
        if let LottieScalarProp::Animated { keyframes } = t.rotation.unwrap() {
            assert_eq!(keyframes[1].start, 90.0);
        } else {
            panic!();
        }
    }

    #[test]
    fn skew_and_matrix_are_skipped() {
        let mut logs = mk_logs();
        let animations = vec![
            anim_transform(
                SvgTransformKind::SkewX,
                SvgAnimationAdditive::Sum,
                vec!["0", "10"],
                vec![0.0, 1.0],
                1.0,
            ),
            anim_transform(
                SvgTransformKind::Matrix,
                SvgAnimationAdditive::Sum,
                vec!["1 0 0 1 0 0", "1 0 0 1 10 10"],
                vec![0.0, 1.0],
                1.0,
            ),
        ];
        let t = map_transforms(&animations, 60.0, &mut logs);
        assert!(t.position.is_none());
        assert!(t.scale.is_none());
        assert!(t.rotation.is_none());
        assert!(t.anchor.is_none());
    }
}
