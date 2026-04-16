//! Port of `lib/src/data/mappers/opacity_mapper.dart`.
//!
//! Converts an `<animate attributeName="opacity">` node into a Lottie
//! `LottieScalarProp`. SVG opacity lives in `[0, 1]`, Lottie in `[0, 100]`,
//! so every keyframe value is scaled by 100.

use crate::domain::{
    LottieScalarKeyframe, LottieScalarProp, SvgAnimationCommon,
};
use crate::log::LogCollector;
use crate::map::keyspline;

/// Default Lottie frame rate used to convert SMIL's normalised keyTimes
/// into frame numbers. Mirrors the Dart default.
pub const DEFAULT_FRAME_RATE: f64 = 60.0;

/// Maps an opacity animation to a `LottieScalarProp::Animated`.
///
/// `anim` is expected to be the common fields of an
/// `SvgAnimationNode::Animate { attribute_name: "opacity", .. }`. If the
/// timeline has a single frame we emit it as `Animated` anyway for
/// parity with the Dart port — the serializer handles the degenerate
/// case.
pub fn map_opacity(
    anim: &SvgAnimationCommon,
    frame_rate: f64,
    logs: &mut LogCollector,
) -> LottieScalarProp {
    let parsed: Vec<f64> = anim
        .keyframes
        .values
        .iter()
        .map(|v| v.trim().parse::<f64>().unwrap_or(0.0))
        .collect();

    logs.trace(
        "map.opacity",
        "building opacity keyframes",
        &[("count", (parsed.len() as u64).into())],
    );

    let mut keyframes = Vec::with_capacity(parsed.len());
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
            start: parsed[i] * 100.0, // Lottie opacity 0..100
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
        BezierSpline, SvgAnimationAdditive, SvgAnimationCalcMode, SvgKeyframes,
    };
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn anim(
        values: Vec<&str>,
        key_times: Vec<f64>,
        calc_mode: SvgAnimationCalcMode,
        splines: Vec<BezierSpline>,
        dur: f64,
    ) -> SvgAnimationCommon {
        SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: false,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times,
                values: values.into_iter().map(String::from).collect(),
                calc_mode,
                key_splines: splines,
            },
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        }
    }

    #[test]
    fn static_one_scaled_to_100() {
        let mut logs = mk_logs();
        let a = anim(vec!["1"], vec![0.0], SvgAnimationCalcMode::Linear, vec![], 1.0);
        let prop = map_opacity(&a, 60.0, &mut logs);
        match prop {
            LottieScalarProp::Animated { keyframes } => {
                assert_eq!(keyframes.len(), 1);
                assert_eq!(keyframes[0].start, 100.0);
                assert_eq!(keyframes[0].time, 0.0);
            }
            _ => panic!("expected animated"),
        }
    }

    #[test]
    fn animated_zero_to_one_scaled_to_0_100() {
        let mut logs = mk_logs();
        let a = anim(
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationCalcMode::Linear,
            vec![],
            2.0,
        );
        let prop = map_opacity(&a, 60.0, &mut logs);
        match prop {
            LottieScalarProp::Animated { keyframes } => {
                assert_eq!(keyframes.len(), 2);
                assert_eq!(keyframes[0].start, 0.0);
                assert_eq!(keyframes[1].start, 100.0);
                assert_eq!(keyframes[0].time, 0.0);
                // 1.0 * 2.0 * 60 = 120
                assert_eq!(keyframes[1].time, 120.0);
            }
            _ => panic!("expected animated"),
        }
    }

    #[test]
    fn mid_opacity_half_scales_to_50() {
        let mut logs = mk_logs();
        let a = anim(
            vec!["0", "0.5", "1"],
            vec![0.0, 0.5, 1.0],
            SvgAnimationCalcMode::Linear,
            vec![],
            1.0,
        );
        let prop = map_opacity(&a, 60.0, &mut logs);
        if let LottieScalarProp::Animated { keyframes } = prop {
            assert_eq!(keyframes[1].start, 50.0);
        } else {
            panic!();
        }
    }

    #[test]
    fn spline_keyframes_carry_bezier_handles() {
        let mut logs = mk_logs();
        let a = anim(
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationCalcMode::Spline,
            vec![BezierSpline {
                x1: 0.25,
                y1: 0.1,
                x2: 0.25,
                y2: 1.0,
            }],
            1.0,
        );
        let prop = map_opacity(&a, 60.0, &mut logs);
        if let LottieScalarProp::Animated { keyframes } = prop {
            let out0 = keyframes[0].bezier_out.unwrap();
            let in1 = keyframes[1].bezier_in.unwrap();
            assert_eq!((out0.x, out0.y), (0.25, 0.1));
            assert_eq!((in1.x, in1.y), (0.25, 1.0));
            assert!(keyframes[0].bezier_in.is_none());
            assert!(keyframes[1].bezier_out.is_none());
        } else {
            panic!();
        }
    }

    #[test]
    fn discrete_sets_hold_true() {
        let mut logs = mk_logs();
        let a = anim(
            vec!["0", "1"],
            vec![0.0, 1.0],
            SvgAnimationCalcMode::Discrete,
            vec![],
            1.0,
        );
        let prop = map_opacity(&a, 60.0, &mut logs);
        if let LottieScalarProp::Animated { keyframes } = prop {
            assert!(keyframes.iter().all(|k| k.hold));
        } else {
            panic!();
        }
    }
}
