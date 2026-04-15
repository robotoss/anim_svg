//! Port of `lib/src/data/mappers/keyspline_mapper.dart`.
//!
//! Maps SVG SMIL timing (`keyTimes`, `keySplines`, `calcMode`) onto Lottie
//! keyframe bezier handles.
//!
//! Lottie convention for two consecutive keyframes `K[i]` and `K[i+1]`:
//!   - `K[i].o`   = easing out-handle (takes `keySpline.x1/y1`)
//!   - `K[i+1].i` = easing in-handle  (takes `keySpline.x2/y2`)
//!
//! `K[last]` has no spline (animation ends there).

use crate::domain::{BezierHandle, SvgAnimationCalcMode, SvgKeyframes};
use crate::log::LogCollector;

/// Returns the `(bezierOut for K[i], bezierIn for K[i+1])` pair for segment
/// `i`, or `(None, None)` if the segment has no spline defined.
///
/// Linear/paced calcMode yields Lottie's default linear pair: out `(1, 1)`
/// on `K[i]` paired with in `(0, 0)` on `K[i+1]`. Discrete yields `(None,
/// None)` — the caller sets `hold: true` on `K[i]` so the property jumps.
pub fn segment(
    kf: &SvgKeyframes,
    i: usize,
    logs: &mut LogCollector,
) -> (Option<BezierHandle>, Option<BezierHandle>) {
    match kf.calc_mode {
        SvgAnimationCalcMode::Discrete => (None, None),
        SvgAnimationCalcMode::Linear | SvgAnimationCalcMode::Paced => {
            // Lottie linear default: i:(0,0), o:(1,1). We return
            // (out_for_K[i], in_for_K[i+1]) = ((1,1), (0,0)).
            (
                Some(BezierHandle { x: 1.0, y: 1.0 }),
                Some(BezierHandle { x: 0.0, y: 0.0 }),
            )
        }
        SvgAnimationCalcMode::Spline => {
            if i >= kf.key_splines.len() {
                logs.warn(
                    "map.keyspline",
                    "segment index out of range for keySplines",
                    &[
                        ("i", (i as u64).into()),
                        ("len", (kf.key_splines.len() as u64).into()),
                    ],
                );
                return (None, None);
            }
            let s = kf.key_splines[i];
            (
                Some(BezierHandle { x: s.x1, y: s.y1 }),
                Some(BezierHandle { x: s.x2, y: s.y2 }),
            )
        }
    }
}

/// Returns `true` when the calcMode is `discrete`, signalling that each
/// keyframe should `hold` its value until the next one.
pub fn hold(kf: &SvgKeyframes) -> bool {
    kf.calc_mode == SvgAnimationCalcMode::Discrete
}

/// Convenience entry point matching the Dart `KeySplineMapper.toEasing`
/// name for call-site parity. Delegates to [`segment`].
pub fn to_easing(
    kf: &SvgKeyframes,
    i: usize,
    logs: &mut LogCollector,
) -> (Option<BezierHandle>, Option<BezierHandle>) {
    segment(kf, i, logs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::BezierSpline;
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn kf(calc_mode: SvgAnimationCalcMode, splines: Vec<BezierSpline>) -> SvgKeyframes {
        SvgKeyframes {
            key_times: vec![0.0, 1.0],
            values: vec!["0".to_string(), "1".to_string()],
            calc_mode,
            key_splines: splines,
        }
    }

    #[test]
    fn discrete_yields_none_and_hold() {
        let mut logs = mk_logs();
        let k = kf(SvgAnimationCalcMode::Discrete, vec![]);
        let (o, i) = segment(&k, 0, &mut logs);
        assert!(o.is_none() && i.is_none());
        assert!(hold(&k));
    }

    #[test]
    fn linear_yields_default_linear_handles() {
        let mut logs = mk_logs();
        let k = kf(SvgAnimationCalcMode::Linear, vec![]);
        let (o, i) = segment(&k, 0, &mut logs);
        let o = o.unwrap();
        let i = i.unwrap();
        assert_eq!((o.x, o.y), (1.0, 1.0));
        assert_eq!((i.x, i.y), (0.0, 0.0));
        assert!(!hold(&k));
    }

    #[test]
    fn spline_pulls_control_points_from_keysplines() {
        let mut logs = mk_logs();
        let k = kf(
            SvgAnimationCalcMode::Spline,
            vec![BezierSpline {
                x1: 0.1,
                y1: 0.2,
                x2: 0.8,
                y2: 0.9,
            }],
        );
        let (o, i) = segment(&k, 0, &mut logs);
        let o = o.unwrap();
        let i = i.unwrap();
        assert_eq!((o.x, o.y), (0.1, 0.2));
        assert_eq!((i.x, i.y), (0.8, 0.9));
    }

    #[test]
    fn spline_out_of_range_returns_none() {
        let mut logs = mk_logs();
        let k = kf(SvgAnimationCalcMode::Spline, vec![]);
        let (o, i) = segment(&k, 5, &mut logs);
        assert!(o.is_none() && i.is_none());
    }

    #[test]
    fn to_easing_is_alias_for_segment() {
        let mut logs = mk_logs();
        let k = kf(SvgAnimationCalcMode::Linear, vec![]);
        let a = segment(&k, 0, &mut logs);
        let b = to_easing(&k, 0, &mut logs);
        assert_eq!(a.0.map(|h| (h.x, h.y)), b.0.map(|h| (h.x, h.y)));
        assert_eq!(a.1.map(|h| (h.x, h.y)), b.1.map(|h| (h.x, h.y)));
    }
}
