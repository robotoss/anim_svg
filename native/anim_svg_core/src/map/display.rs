//! Port of `lib/src/data/mappers/display_mapper.dart`.
//!
//! Maps `<animate attributeName="display" values="none;inline;none">` onto a
//! hold-interpolated opacity track (Lottie has no discrete visibility
//! channel).
//!
//! `inline|block|...` → 100; `none` → 0. All keyframes are holds (`h:1`).

use crate::domain::{LottieScalarKeyframe, LottieScalarProp, SvgAnimationNode};
use crate::log::LogCollector;

/// Default Lottie frame rate if no override is supplied (parity with Dart
/// `DisplayMapper({this.frameRate = 60})`).
pub const DEFAULT_FRAME_RATE: f64 = 60.0;

/// Mirrors `DisplayMapper.map`. Accepts any `SvgAnimationNode`; non-`animate`
/// or non-`display` inputs log a warning and return a no-op static 100 track.
pub fn map(
    anim: &SvgAnimationNode,
    frame_rate: f64,
    logs: &mut LogCollector,
) -> LottieScalarProp {
    let (attribute_name, common) = match anim {
        SvgAnimationNode::Animate {
            attribute_name,
            common,
        } => (attribute_name.as_str(), common),
        SvgAnimationNode::AnimateTransform { .. } => {
            logs.warn(
                "map.display",
                "expected <animate attributeName=display>, got <animateTransform>",
                &[],
            );
            return LottieScalarProp::Static { value: 100.0 };
        }
    };

    if attribute_name != "display" {
        logs.warn(
            "map.display",
            "unexpected attributeName for display mapper",
            &[("attributeName", attribute_name.to_string().into())],
        );
    }

    let kf = &common.keyframes;
    let mut keyframes: Vec<LottieScalarKeyframe> = Vec::with_capacity(kf.values.len());
    for i in 0..kf.values.len() {
        let v = kf.values[i].trim();
        let opacity = if v == "none" { 0.0 } else { 100.0 };
        let frame = kf.key_times[i] * common.dur_seconds * frame_rate;
        keyframes.push(LottieScalarKeyframe {
            time: frame,
            start: opacity,
            hold: true,
            bezier_in: None,
            bezier_out: None,
        });
    }
    LottieScalarProp::Animated { keyframes }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon, SvgKeyframes,
        SvgTransformKind,
    };
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn mk_display_anim(values: &[&str], key_times: Vec<f64>, dur: f64) -> SvgAnimationNode {
        SvgAnimationNode::Animate {
            attribute_name: "display".to_string(),
            common: SvgAnimationCommon {
                dur_seconds: dur,
                repeat_indefinite: false,
                additive: SvgAnimationAdditive::Replace,
                keyframes: SvgKeyframes {
                    key_times,
                    values: values.iter().map(|s| s.to_string()).collect(),
                    calc_mode: SvgAnimationCalcMode::Discrete,
                    key_splines: Vec::new(),
                },
                delay_seconds: 0.0,
                direction: Default::default(),
                fill_mode: Default::default(),
            },
        }
    }

    #[test]
    fn none_maps_to_zero_inline_to_hundred_all_holds() {
        let mut logs = mk_logs();
        let anim = mk_display_anim(&["inline", "none", "inline"], vec![0.0, 0.5, 1.0], 2.0);
        let out = map(&anim, 60.0, &mut logs);
        match out {
            LottieScalarProp::Animated { keyframes } => {
                assert_eq!(keyframes.len(), 3);
                assert_eq!(keyframes[0].start, 100.0);
                assert_eq!(keyframes[1].start, 0.0);
                assert_eq!(keyframes[2].start, 100.0);
                // All holds.
                assert!(keyframes.iter().all(|k| k.hold));
                // Frame = keyTime * dur * fps: 0, 60, 120.
                assert_eq!(keyframes[0].time, 0.0);
                assert_eq!(keyframes[1].time, 60.0);
                assert_eq!(keyframes[2].time, 120.0);
            }
            _ => panic!("expected animated"),
        }
    }

    #[test]
    fn block_and_other_non_none_values_map_to_hundred() {
        let mut logs = mk_logs();
        let anim = mk_display_anim(&["block", "none"], vec![0.0, 1.0], 1.0);
        let out = map(&anim, 30.0, &mut logs);
        match out {
            LottieScalarProp::Animated { keyframes } => {
                assert_eq!(keyframes[0].start, 100.0);
                assert_eq!(keyframes[1].start, 0.0);
                assert_eq!(keyframes[1].time, 30.0);
            }
            _ => panic!(),
        }
    }

    #[test]
    fn trims_whitespace_around_display_value() {
        let mut logs = mk_logs();
        let anim = mk_display_anim(&[" none ", "  inline "], vec![0.0, 1.0], 1.0);
        let out = map(&anim, 60.0, &mut logs);
        match out {
            LottieScalarProp::Animated { keyframes } => {
                assert_eq!(keyframes[0].start, 0.0);
                assert_eq!(keyframes[1].start, 100.0);
            }
            _ => panic!(),
        }
    }

    #[test]
    fn wrong_attribute_logs_warning() {
        let mut logs = mk_logs();
        let anim = SvgAnimationNode::Animate {
            attribute_name: "opacity".to_string(),
            common: SvgAnimationCommon {
                dur_seconds: 1.0,
                repeat_indefinite: false,
                additive: SvgAnimationAdditive::Replace,
                keyframes: SvgKeyframes {
                    key_times: vec![0.0, 1.0],
                    values: vec!["inline".to_string(), "none".to_string()],
                    calc_mode: SvgAnimationCalcMode::Discrete,
                    key_splines: Vec::new(),
                },
                delay_seconds: 0.0,
                direction: Default::default(),
                fill_mode: Default::default(),
            },
        };
        let _ = map(&anim, 60.0, &mut logs);
        let entries = logs.into_entries();
        assert!(entries.iter().any(|e| e.stage == "map.display"));
    }

    #[test]
    fn animate_transform_returns_static_and_logs() {
        let mut logs = mk_logs();
        let anim = SvgAnimationNode::AnimateTransform {
            kind: SvgTransformKind::Translate,
            common: SvgAnimationCommon {
                dur_seconds: 1.0,
                repeat_indefinite: false,
                additive: SvgAnimationAdditive::Replace,
                keyframes: SvgKeyframes {
                    key_times: vec![0.0, 1.0],
                    values: vec!["0 0".to_string(), "10 10".to_string()],
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: Vec::new(),
                },
                delay_seconds: 0.0,
                direction: Default::default(),
                fill_mode: Default::default(),
            },
        };
        let out = map(&anim, 60.0, &mut logs);
        match out {
            LottieScalarProp::Static { value } => assert_eq!(value, 100.0),
            _ => panic!("expected static"),
        }
        assert!(!logs.into_entries().is_empty());
    }
}
