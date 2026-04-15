//! Port of `lib/src/data/mappers/animation_normalizer.dart`.
//!
//! Bakes CSS-only animation options (`animation-direction`,
//! `animation-delay`, `animation-fill-mode`) into the underlying keyframe
//! arrays so downstream mappers can treat every track as a plain forward
//! timeline with `direction=normal` and `delaySeconds=0`.
//!
//! Transformations:
//! - `reverse` → reverse the `values` list (keyTimes remain monotone 0..1
//!   and the same spline stack applies segment-wise).
//! - `alternate` → concatenate forward + reversed-tail into a 2×length
//!   values list; keyTimes scaled to [0,0.5] then [0.5,1]; `durSeconds`
//!   doubled; keySplines replicated (forward + reversed) per segment.
//! - `alternate-reverse` → same as alternate but start reversed.
//! - `delaySeconds > 0` with finite repeat → prepend a hold keyframe at
//!   `t=0` holding `values[0]`; keyTimes rescaled into the new `dur =
//!   dur + delay`. For `repeatIndefinite=true`, delay is logged and
//!   skipped (Lottie loops the whole outPoint so a pre-roll hold would
//!   distort every subsequent cycle).
//! - `fillMode` is left untouched: Lottie layers freeze the last keyframe
//!   past `outPoint` by default (`forwards`/`both`). `backwards` with
//!   delay is handled implicitly by the prepended hold keyframe.

use crate::domain::{
    BezierSpline, SvgAnimationCalcMode, SvgAnimationDirection, SvgAnimationNode, SvgKeyframes,
};
use crate::log::LogCollector;

/// Public entry mirroring the Dart `AnimationNormalizer.normalize`.
pub fn normalize(anims: Vec<SvgAnimationNode>, logs: &mut LogCollector) -> Vec<SvgAnimationNode> {
    anims
        .into_iter()
        .map(|a| normalize_anim(a, logs))
        .collect()
}

fn normalize_anim(mut a: SvgAnimationNode, logs: &mut LogCollector) -> SvgAnimationNode {
    let common = a.common_mut();

    if common.direction != SvgAnimationDirection::Normal {
        let reversed = reversed(&common.keyframes);
        match common.direction {
            SvgAnimationDirection::Reverse => {
                common.keyframes = reversed;
            }
            SvgAnimationDirection::Alternate => {
                let merged = concat(&common.keyframes, &reversed);
                common.keyframes = merged;
                common.dur_seconds *= 2.0;
            }
            SvgAnimationDirection::AlternateReverse => {
                let merged = concat(&reversed, &common.keyframes);
                common.keyframes = merged;
                common.dur_seconds *= 2.0;
            }
            SvgAnimationDirection::Normal => {}
        }
        common.direction = SvgAnimationDirection::Normal;
    }

    if common.delay_seconds > 0.0 {
        if common.repeat_indefinite {
            let delay = common.delay_seconds;
            logs.warn(
                "map.normalize.anim",
                "animation-delay ignored on repeatIndefinite track",
                &[("delay", delay.into())],
            );
        } else {
            let total_dur = common.dur_seconds + common.delay_seconds;
            let hold_frac = common.delay_seconds / total_dur;
            let mut rescaled = Vec::with_capacity(common.keyframes.key_times.len() + 1);
            rescaled.push(0.0);
            for t in &common.keyframes.key_times {
                rescaled.push(hold_frac + t * (1.0 - hold_frac));
            }
            let mut new_values = Vec::with_capacity(common.keyframes.values.len() + 1);
            new_values.push(common.keyframes.values[0].clone());
            new_values.extend(common.keyframes.values.iter().cloned());
            // Prepend a discrete hold segment so the intro phase really
            // freezes — using linear would interpolate from values[0] to
            // values[0] (a no-op), but discrete conveys intent and avoids
            // emitting a redundant handle.
            let splines = if common.keyframes.calc_mode == SvgAnimationCalcMode::Spline {
                let mut v = Vec::with_capacity(common.keyframes.key_splines.len() + 1);
                v.push(BezierSpline {
                    x1: 0.0,
                    y1: 0.0,
                    x2: 1.0,
                    y2: 1.0,
                });
                v.extend(common.keyframes.key_splines.iter().copied());
                v
            } else {
                Vec::new()
            };
            common.keyframes = SvgKeyframes {
                key_times: rescaled,
                values: new_values,
                calc_mode: common.keyframes.calc_mode,
                key_splines: splines,
            };
            common.dur_seconds = total_dur;
        }
        common.delay_seconds = 0.0;
    }

    a
}

fn reversed(kfs: &SvgKeyframes) -> SvgKeyframes {
    let new_times: Vec<f64> = kfs.key_times.iter().rev().map(|t| 1.0 - t).collect();
    let new_values: Vec<String> = kfs.values.iter().rev().cloned().collect();
    let new_splines = if kfs.calc_mode == SvgAnimationCalcMode::Spline {
        kfs.key_splines
            .iter()
            .rev()
            // Mirror the bezier (CSS reverse reflects easing across x=y=0.5).
            .map(|s| BezierSpline {
                x1: 1.0 - s.x2,
                y1: 1.0 - s.y2,
                x2: 1.0 - s.x1,
                y2: 1.0 - s.y1,
            })
            .collect()
    } else {
        Vec::new()
    };
    SvgKeyframes {
        key_times: new_times,
        values: new_values,
        calc_mode: kfs.calc_mode,
        key_splines: new_splines,
    }
}

fn concat(a: &SvgKeyframes, b: &SvgKeyframes) -> SvgKeyframes {
    // Halve both tracks and merge, skipping the duplicate mid-point.
    let mut times: Vec<f64> = a.key_times.iter().map(|t| t * 0.5).collect();
    times.extend(b.key_times.iter().skip(1).map(|t| 0.5 + t * 0.5));
    let mut values: Vec<String> = a.values.iter().cloned().collect();
    values.extend(b.values.iter().skip(1).cloned());
    let is_spline =
        a.calc_mode == SvgAnimationCalcMode::Spline || b.calc_mode == SvgAnimationCalcMode::Spline;
    let splines = if is_spline {
        let mut v = Vec::with_capacity(a.key_splines.len() + b.key_splines.len());
        v.extend(a.key_splines.iter().copied());
        v.extend(b.key_splines.iter().copied());
        v
    } else {
        Vec::new()
    };
    let mode = if is_spline {
        SvgAnimationCalcMode::Spline
    } else {
        a.calc_mode
    };
    SvgKeyframes {
        key_times: times,
        values,
        calc_mode: mode,
        key_splines: splines,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{SvgAnimationAdditive, SvgAnimationCommon, SvgAnimationFillMode};
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn mk_anim(common: SvgAnimationCommon) -> SvgAnimationNode {
        SvgAnimationNode::Animate {
            attribute_name: "opacity".to_string(),
            common,
        }
    }

    fn mk_common(
        dur: f64,
        values: Vec<&str>,
        key_times: Vec<f64>,
        direction: SvgAnimationDirection,
        delay: f64,
        repeat: bool,
    ) -> SvgAnimationCommon {
        SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: repeat,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times,
                values: values.into_iter().map(|s| s.to_string()).collect(),
                calc_mode: SvgAnimationCalcMode::Linear,
                key_splines: Vec::new(),
            },
            delay_seconds: delay,
            direction,
            fill_mode: SvgAnimationFillMode::None,
        }
    }

    #[test]
    fn delay_bake_prepends_hold_keyframe() {
        let c = mk_common(
            1.0,
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationDirection::Normal,
            1.0,
            false,
        );
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["0", "0", "1"]);
        assert_eq!(k.key_times, vec![0.0, 0.5, 1.0]);
        assert_eq!(out[0].common().dur_seconds, 2.0);
        assert_eq!(out[0].common().delay_seconds, 0.0);
    }

    #[test]
    fn direction_reverse_flips_values() {
        let c = mk_common(
            1.0,
            vec!["a", "b", "c"],
            vec![0.0, 0.5, 1.0],
            SvgAnimationDirection::Reverse,
            0.0,
            false,
        );
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["c", "b", "a"]);
        assert_eq!(k.key_times, vec![0.0, 0.5, 1.0]);
        assert_eq!(out[0].common().direction, SvgAnimationDirection::Normal);
        assert_eq!(out[0].common().dur_seconds, 1.0);
    }

    #[test]
    fn direction_alternate_doubles_timeline() {
        let c = mk_common(
            1.0,
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationDirection::Alternate,
            0.0,
            false,
        );
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["0", "1", "0"]);
        assert_eq!(k.key_times, vec![0.0, 0.5, 1.0]);
        assert_eq!(out[0].common().dur_seconds, 2.0);
        assert_eq!(out[0].common().direction, SvgAnimationDirection::Normal);
    }

    #[test]
    fn direction_alternate_reverse_starts_reversed() {
        let c = mk_common(
            1.0,
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationDirection::AlternateReverse,
            0.0,
            false,
        );
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["1", "0", "1"]);
        assert_eq!(k.key_times, vec![0.0, 0.5, 1.0]);
        assert_eq!(out[0].common().dur_seconds, 2.0);
    }

    #[test]
    fn fill_mode_forwards_is_passthrough() {
        // Lottie freezes last keyframe past outPoint by default; the
        // normalizer just needs to leave fillMode intact so downstream
        // mappers can read it if they want.
        let mut c = mk_common(
            1.0,
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationDirection::Normal,
            0.0,
            false,
        );
        c.fill_mode = SvgAnimationFillMode::Forwards;
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        assert_eq!(out[0].common().fill_mode, SvgAnimationFillMode::Forwards);
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["0", "1"]);
        assert_eq!(k.key_times, vec![0.0, 1.0]);
    }

    #[test]
    fn repeat_indefinite_delay_is_skipped_and_preserved() {
        let c = mk_common(
            1.0,
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationDirection::Normal,
            2.0,
            true,
        );
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        assert!(out[0].common().repeat_indefinite);
        assert_eq!(out[0].common().dur_seconds, 1.0);
        // Delay is zeroed even though we couldn't bake it; that matches
        // the Dart behaviour (caller now sees a clean `delaySeconds=0`
        // timeline and the warning is in the log).
        assert_eq!(out[0].common().delay_seconds, 0.0);
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["0", "1"]);
    }

    #[test]
    fn no_op_when_nothing_to_bake() {
        let c = mk_common(
            1.0,
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationDirection::Normal,
            0.0,
            false,
        );
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        assert_eq!(out[0].common().dur_seconds, 1.0);
        assert_eq!(out[0].common().direction, SvgAnimationDirection::Normal);
        assert_eq!(out[0].common().delay_seconds, 0.0);
        let k = &out[0].common().keyframes;
        assert_eq!(k.values, vec!["0", "1"]);
        assert_eq!(k.key_times, vec![0.0, 1.0]);
    }

    #[test]
    fn spline_reverse_mirrors_easing() {
        let mut kfs = SvgKeyframes {
            key_times: vec![0.0, 1.0],
            values: vec!["0".to_string(), "1".to_string()],
            calc_mode: SvgAnimationCalcMode::Spline,
            key_splines: vec![BezierSpline {
                x1: 0.1,
                y1: 0.2,
                x2: 0.3,
                y2: 0.4,
            }],
        };
        let c = SvgAnimationCommon {
            dur_seconds: 1.0,
            repeat_indefinite: false,
            additive: SvgAnimationAdditive::Replace,
            keyframes: std::mem::replace(
                &mut kfs,
                SvgKeyframes {
                    key_times: vec![],
                    values: vec![],
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: vec![],
                },
            ),
            delay_seconds: 0.0,
            direction: SvgAnimationDirection::Reverse,
            fill_mode: SvgAnimationFillMode::None,
        };
        let out = normalize(vec![mk_anim(c)], &mut mk_logs());
        let s = &out[0].common().keyframes.key_splines[0];
        // (1 - x2, 1 - y2, 1 - x1, 1 - y1) = (0.7, 0.6, 0.9, 0.8)
        assert!((s.x1 - 0.7).abs() < 1e-9);
        assert!((s.y1 - 0.6).abs() < 1e-9);
        assert!((s.x2 - 0.9).abs() < 1e-9);
        assert!((s.y2 - 0.8).abs() < 1e-9);
    }
}
