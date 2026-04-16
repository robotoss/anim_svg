//! Port of `lib/src/data/mappers/opacity_merge.dart`.
//!
//! Merges every `<animate attributeName="display">` + `<animate
//! attributeName="opacity">` track on a single element into one unified
//! `opacity` track. The Dart source folds straight into Lottie's
//! scalar-keyframe shape; this Rust port keeps the output in SVG space
//! as a single `SvgAnimationNode::Animate { attribute_name: "opacity" }`
//! — the Lottie mapping is downstream.
//!
//! Semantics (identical to Dart):
//! - Each display animate is a 0/100 step gate (`"none"` → 0, else 100).
//! - Each opacity animate is a 0..100 ramp (fraction × 100).
//! - Sample at the union of all keyframe times; multiply fractions:
//!   `100 × Π(v_i / 100)`.
//! - When a step gate flips, a hold-pair is inserted at `t - ε` so the
//!   pre-step ramp lands cleanly before the drop.
//! - Between keyframes where the analytical product is constant
//!   (gate-closed or all tracks static), the emitted keyframe is held.

use crate::domain::{
    SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode, SvgKeyframes,
};
use crate::log::LogCollector;

/// Sub-frame epsilon used when inserting the hold-pair just before a
/// step transition. Expressed in absolute seconds — small enough that
/// downstream frame quantisation collapses it to the preceding frame.
const PRE_STEP_EPSILON_SECONDS: f64 = 1.0 / 60_000.0;

/// A single already-parsed animation input. `values` carry the raw
/// strings from the SVG (`"none"` / `"inline"` for display, decimal
/// fractions 0..1 for opacity).
#[derive(Debug, Clone)]
pub struct InputTrack {
    pub common: SvgAnimationCommon,
}

/// Convenience constructor — splits a caller-provided animation-node
/// list into the display/opacity buckets this mapper needs.
pub fn partition<'a>(
    animations: &'a [SvgAnimationNode],
) -> (Vec<&'a SvgAnimationCommon>, Vec<&'a SvgAnimationCommon>) {
    let mut displays = Vec::new();
    let mut opacities = Vec::new();
    for a in animations {
        if let SvgAnimationNode::Animate {
            attribute_name,
            common,
        } = a
        {
            match attribute_name.as_str() {
                "display" => displays.push(common),
                "opacity" => opacities.push(common),
                _ => {}
            }
        }
    }
    (displays, opacities)
}

/// Merges the given display + opacity tracks into a single SVG
/// `opacity` animation. Returns:
/// - `None` when both slices are empty (caller should keep the static
///   default of 1.0 / 100%).
/// - `Some(original)` when there's exactly one input track and nothing
///   to merge — returns it as an `Animate { attribute_name: "opacity" }`
///   (display-only inputs are converted to a 0/100 discrete opacity
///   track).
/// - `Some(merged)` otherwise — a freshly constructed merged track.
pub fn merge(
    displays: &[&SvgAnimationCommon],
    opacities: &[&SvgAnimationCommon],
    logs: &mut LogCollector,
) -> Option<SvgAnimationNode> {
    if displays.is_empty() && opacities.is_empty() {
        return None;
    }
    if displays.is_empty() && opacities.len() == 1 {
        return Some(SvgAnimationNode::Animate {
            attribute_name: "opacity".into(),
            common: (*opacities[0]).clone(),
        });
    }
    if opacities.is_empty() && displays.len() == 1 {
        // Convert the display-only gate to an equivalent opacity step
        // track. Values are "none" / else → "0" / "1".
        let d = displays[0];
        let values: Vec<String> = d
            .keyframes
            .values
            .iter()
            .map(|v| {
                if v.trim() == "none" {
                    "0".to_string()
                } else {
                    "1".to_string()
                }
            })
            .collect();
        return Some(SvgAnimationNode::Animate {
            attribute_name: "opacity".into(),
            common: SvgAnimationCommon {
                dur_seconds: d.dur_seconds,
                repeat_indefinite: d.repeat_indefinite,
                additive: d.additive,
                keyframes: SvgKeyframes {
                    key_times: d.keyframes.key_times.clone(),
                    values,
                    calc_mode: SvgAnimationCalcMode::Discrete,
                    key_splines: Vec::new(),
                },
                delay_seconds: d.delay_seconds,
                direction: d.direction,
                fill_mode: d.fill_mode,
            },
        });
    }

    if opacities.iter().any(|o| !o.keyframes.key_splines.is_empty()) {
        logs.warn(
            "map.opacity_merge",
            "dropping opacity keysplines — merge resamples to linear segments",
            &[
                ("displays", (displays.len() as u64).into()),
                ("opacities", (opacities.len() as u64).into()),
            ],
        );
    }

    let mut tracks: Vec<Track> = Vec::new();
    for d in displays {
        tracks.push(Track::from_display(d));
    }
    for o in opacities {
        tracks.push(Track::from_opacity(o));
    }

    // Union of all absolute-second keyframe times.
    let mut times: Vec<f64> = Vec::new();
    for t in &tracks {
        for s in &t.samples {
            if !times.iter().any(|x| (*x - s.time).abs() < 1e-9) {
                times.push(s.time);
            }
        }
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if times.is_empty() {
        return None;
    }

    let mut out: Vec<Keyframe> = Vec::new();
    for i in 0..times.len() {
        let t = times[i];
        let step_jump_here = step_transition_at(&tracks, t);
        if i > 0 && step_jump_here && !out.last().map(|k| k.hold).unwrap_or(false) {
            out.push(Keyframe {
                time: t - PRE_STEP_EPSILON_SECONDS,
                value: product(&tracks, t, true),
                hold: true,
            });
        }
        let value = product(&tracks, t, false);
        let hold = (i + 1 < times.len()) && segment_hold(&tracks, t, times[i + 1]);
        out.push(Keyframe {
            time: t,
            value,
            hold,
        });
    }

    // Detect a fully-static merge (every value equal) → collapse to a
    // two-frame constant track.
    let first_value = out[0].value;
    let all_static = out
        .iter()
        .all(|k| (k.value - first_value).abs() < 1e-6);

    // Determine output dur & normalise keytimes to 0..1.
    let total_dur = out.last().map(|k| k.time).unwrap_or(1.0).max(1e-9);
    let base_common = opacities.first().copied().or_else(|| displays.first().copied());
    let repeat_indefinite = base_common.map(|c| c.repeat_indefinite).unwrap_or(false);
    let delay_seconds = base_common.map(|c| c.delay_seconds).unwrap_or(0.0);
    let direction = base_common.map(|c| c.direction).unwrap_or_default();
    let fill_mode = base_common.map(|c| c.fill_mode).unwrap_or_default();

    if all_static {
        return Some(SvgAnimationNode::Animate {
            attribute_name: "opacity".into(),
            common: SvgAnimationCommon {
                dur_seconds: total_dur,
                repeat_indefinite,
                additive: SvgAnimationAdditive::Replace,
                keyframes: SvgKeyframes {
                    key_times: vec![0.0, 1.0],
                    values: vec![fmt_fraction(first_value), fmt_fraction(first_value)],
                    calc_mode: SvgAnimationCalcMode::Linear,
                    key_splines: Vec::new(),
                },
                delay_seconds,
                direction,
                fill_mode,
            },
        });
    }

    // Choose overall calc_mode: if any emitted keyframe holds we flag
    // discrete for that pair; SVG `calcMode` is a single attribute so
    // fall back to `linear` and rely on the hold flag convention only
    // when the *entire* track is a gate. Dart emits a linear track with
    // hold flags on individual keyframes — we mirror that by emitting
    // `linear` plus a trailing duplicate value on the held segment
    // (classic SVG hold idiom).
    let mut key_times: Vec<f64> = Vec::with_capacity(out.len());
    let mut values: Vec<String> = Vec::with_capacity(out.len());
    for i in 0..out.len() {
        let k = &out[i];
        key_times.push((k.time / total_dur).clamp(0.0, 1.0));
        values.push(fmt_fraction(k.value));
        // Hold flag → duplicate the current value at the *next*
        // keyframe's time so the linear interpolation produces a flat
        // segment. Safe because the caller's union of times already
        // placed that next frame.
        if k.hold && i + 1 < out.len() {
            // Leave the next slot unchanged — but override its string
            // value after the loop finishes, so its time stays correct
            // while its value equals the hold's value.
            // This gets handled below.
        }
    }
    // Apply hold-flag value propagation.
    for i in 0..out.len() {
        if out[i].hold && i + 1 < out.len() {
            values[i + 1] = fmt_fraction(out[i].value);
        }
    }

    Some(SvgAnimationNode::Animate {
        attribute_name: "opacity".into(),
        common: SvgAnimationCommon {
            dur_seconds: total_dur,
            repeat_indefinite,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times,
                values,
                calc_mode: SvgAnimationCalcMode::Linear,
                key_splines: Vec::new(),
            },
            delay_seconds,
            direction,
            fill_mode,
        },
    })
}

fn product(tracks: &[Track], t: f64, pre_step: bool) -> f64 {
    let mut p = 1.0_f64;
    for trk in tracks {
        let v = if pre_step && trk.is_step {
            trk.sample_just_before(t)
        } else {
            trk.sample(t)
        };
        p *= v / 100.0;
    }
    p * 100.0
}

fn step_transition_at(tracks: &[Track], t: f64) -> bool {
    for trk in tracks {
        if !trk.is_step {
            continue;
        }
        if (trk.sample_just_before(t) - trk.sample(t)).abs() > 1e-6 {
            return true;
        }
    }
    false
}

/// Returns true when the analytical product is constant on (t0, t1)
/// but the endpoint values differ (so a `hold` is required). Covers
/// gate-closed (some step track is 0) and both tracks static on the
/// segment.
fn segment_hold(tracks: &[Track], t0: f64, t1: f64) -> bool {
    let p0 = product(tracks, t0, false);
    let p1 = product(tracks, t1, false);
    if (p0 - p1).abs() < 1e-6 {
        return false;
    }
    for trk in tracks {
        if !trk.is_step {
            continue;
        }
        if trk.sample(t0).abs() < 1e-6 {
            return true;
        }
    }
    let any_linear_changes = tracks.iter().any(|trk| {
        !trk.is_step && (trk.sample(t0) - trk.sample(t1)).abs() > 1e-6
    });
    !any_linear_changes
}

/// Opacity is written as a 0..1 decimal fraction.
fn fmt_fraction(pct: f64) -> String {
    let v = pct / 100.0;
    if !v.is_finite() {
        return "0".to_string();
    }
    if v == v.trunc() {
        return format!("{:.0}", v);
    }
    let rounded = format!("{:.6}", v).parse::<f64>().unwrap_or(v);
    rounded.to_string()
}

#[derive(Debug, Clone, Copy)]
struct Sample {
    time: f64,
    value: f64,
}

#[derive(Debug, Clone, Copy)]
struct Keyframe {
    time: f64,
    value: f64,
    hold: bool,
}

struct Track {
    samples: Vec<Sample>,
    is_step: bool,
}

impl Track {
    fn from_display(a: &SvgAnimationCommon) -> Self {
        let kf = &a.keyframes;
        let samples = (0..kf.values.len())
            .map(|i| Sample {
                time: kf.key_times[i] * a.dur_seconds,
                value: if kf.values[i].trim() == "none" {
                    0.0
                } else {
                    100.0
                },
            })
            .collect();
        Track {
            samples,
            is_step: true,
        }
    }

    fn from_opacity(a: &SvgAnimationCommon) -> Self {
        let kf = &a.keyframes;
        let samples = (0..kf.values.len())
            .map(|i| Sample {
                time: kf.key_times[i] * a.dur_seconds,
                value: kf.values[i].trim().parse::<f64>().unwrap_or(0.0) * 100.0,
            })
            .collect();
        Track {
            samples,
            is_step: kf.calc_mode == SvgAnimationCalcMode::Discrete,
        }
    }

    fn sample(&self, t: f64) -> f64 {
        if self.samples.is_empty() {
            return 100.0;
        }
        let first = self.samples[0];
        let last = self.samples[self.samples.len() - 1];
        if t <= first.time {
            return first.value;
        }
        if t >= last.time {
            return last.value;
        }
        if self.is_step {
            let mut v = first.value;
            for k in &self.samples {
                if k.time <= t {
                    v = k.value;
                } else {
                    break;
                }
            }
            return v;
        }
        for i in 0..self.samples.len().saturating_sub(1) {
            let a = self.samples[i];
            let b = self.samples[i + 1];
            if t >= a.time && t <= b.time {
                let alpha = if (b.time - a.time).abs() < 1e-12 {
                    0.0
                } else {
                    (t - a.time) / (b.time - a.time)
                };
                return a.value + (b.value - a.value) * alpha;
            }
        }
        last.value
    }

    fn sample_just_before(&self, t: f64) -> f64 {
        if !self.is_step {
            return self.sample(t);
        }
        if self.samples.is_empty() {
            return 100.0;
        }
        let first = self.samples[0];
        if t <= first.time {
            return first.value;
        }
        let mut v = first.value;
        for k in &self.samples {
            if k.time < t {
                v = k.value;
            } else {
                break;
            }
        }
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn opacity(values: &[&str], key_times: &[f64], dur: f64) -> SvgAnimationCommon {
        SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: false,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times: key_times.to_vec(),
                values: values.iter().map(|s| s.to_string()).collect(),
                calc_mode: SvgAnimationCalcMode::Linear,
                key_splines: Vec::new(),
            },
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        }
    }

    fn display(values: &[&str], key_times: &[f64], dur: f64) -> SvgAnimationCommon {
        SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: false,
            additive: SvgAnimationAdditive::Replace,
            keyframes: SvgKeyframes {
                key_times: key_times.to_vec(),
                values: values.iter().map(|s| s.to_string()).collect(),
                calc_mode: SvgAnimationCalcMode::Discrete,
                key_splines: Vec::new(),
            },
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        }
    }

    #[test]
    fn empty_inputs_return_none() {
        let mut l = logs();
        assert!(merge(&[], &[], &mut l).is_none());
    }

    #[test]
    fn single_opacity_passthrough() {
        let mut l = logs();
        let o = opacity(&["0", "1"], &[0.0, 1.0], 1.0);
        let out = merge(&[], &[&o], &mut l).unwrap();
        match out {
            SvgAnimationNode::Animate {
                attribute_name,
                common,
            } => {
                assert_eq!(attribute_name, "opacity");
                assert_eq!(common.keyframes.values, vec!["0", "1"]);
            }
            _ => panic!(),
        }
    }

    #[test]
    fn single_display_becomes_discrete_opacity() {
        let mut l = logs();
        let d = display(&["inline", "none", "inline"], &[0.0, 0.5, 1.0], 2.0);
        let out = merge(&[&d], &[], &mut l).unwrap();
        match out {
            SvgAnimationNode::Animate {
                attribute_name,
                common,
            } => {
                assert_eq!(attribute_name, "opacity");
                assert_eq!(common.keyframes.values, vec!["1", "0", "1"]);
                assert_eq!(common.keyframes.calc_mode, SvgAnimationCalcMode::Discrete);
            }
            _ => panic!(),
        }
    }

    #[test]
    fn display_none_hides_opacity() {
        let mut l = logs();
        // opacity fully on; display none from t=0.5s..1s.
        let o = opacity(&["1", "1"], &[0.0, 1.0], 1.0);
        let d = display(&["inline", "none"], &[0.0, 0.5], 1.0);
        let out = merge(&[&d], &[&o], &mut l).unwrap();
        let common = match &out {
            SvgAnimationNode::Animate { common, .. } => common,
            _ => panic!(),
        };
        // At t=1s (display is "none") the product should be 0.
        let last_v = common.keyframes.values.last().unwrap();
        let last_n: f64 = last_v.parse().unwrap();
        assert!(last_n.abs() < 1e-6, "expected 0, got {}", last_n);
    }

    #[test]
    fn display_visible_preserves_nonzero_opacity() {
        let mut l = logs();
        // opacity ramps 0 → 1 while display stays inline.
        let o = opacity(&["0", "1"], &[0.0, 1.0], 1.0);
        let d = display(&["inline"], &[0.0], 1.0);
        let out = merge(&[&d], &[&o], &mut l).unwrap();
        let common = match &out {
            SvgAnimationNode::Animate { common, .. } => common,
            _ => panic!(),
        };
        // Endpoint at t=1s should still be 1 (fully visible).
        let last: f64 = common.keyframes.values.last().unwrap().parse().unwrap();
        assert!((last - 1.0).abs() < 1e-6, "expected 1, got {}", last);
    }

    #[test]
    fn union_of_keyframe_times_is_correct() {
        let mut l = logs();
        // opacity has keys at 0, 0.5, 1 (s); display has keys at 0, 0.25, 0.75 (s).
        let o = opacity(&["0", "0.5", "1"], &[0.0, 0.5, 1.0], 1.0);
        let d = display(&["inline", "none", "inline"], &[0.0, 0.25, 0.75], 1.0);
        let out = merge(&[&d], &[&o], &mut l).unwrap();
        let common = match &out {
            SvgAnimationNode::Animate { common, .. } => common,
            _ => panic!(),
        };
        // Union: {0, 0.25, 0.5, 0.75, 1.0} → 5 frames. Step transitions
        // insert pre-step hold-pairs (at t=0.25 and t=0.75). Allow for
        // the exact count to be 5 or 7 depending on transitions.
        assert!(
            common.keyframes.values.len() >= 5,
            "expected >=5 frames, got {}",
            common.keyframes.values.len()
        );
        // First time is 0.
        assert!((common.keyframes.key_times[0] - 0.0).abs() < 1e-9);
        // Last time is 1.
        assert!(
            (common.keyframes.key_times.last().unwrap() - 1.0).abs() < 1e-9,
            "last kt = {}",
            common.keyframes.key_times.last().unwrap()
        );
    }

    #[test]
    fn step_transition_inserts_hold_pair() {
        let mut l = logs();
        // Ramp opacity 0 → 1 over 1s, display closes at t=0.5s.
        let o = opacity(&["0", "1"], &[0.0, 1.0], 1.0);
        let d = display(&["inline", "none"], &[0.0, 0.5], 1.0);
        let out = merge(&[&d], &[&o], &mut l).unwrap();
        let common = match &out {
            SvgAnimationNode::Animate { common, .. } => common,
            _ => panic!(),
        };
        // There should be a keyframe at time just before 0.5/1.0 with
        // the pre-step value (~0.5 scaled to fraction).
        let has_pre_step = common.keyframes.key_times.iter().any(|t| (*t - 0.5).abs() < 1e-3 && *t < 0.5);
        assert!(has_pre_step, "expected a pre-step keyframe just before 0.5: {:?}", common.keyframes.key_times);
    }

    #[test]
    fn two_opacity_tracks_multiply() {
        let mut l = logs();
        // Both tracks 0.5 throughout → product = 0.25 (fraction).
        let a = opacity(&["0.5", "0.5"], &[0.0, 1.0], 1.0);
        let b = opacity(&["0.5", "0.5"], &[0.0, 1.0], 1.0);
        let out = merge(&[], &[&a, &b], &mut l).unwrap();
        let common = match &out {
            SvgAnimationNode::Animate { common, .. } => common,
            _ => panic!(),
        };
        // All values should be 0.25.
        for v in &common.keyframes.values {
            let n: f64 = v.parse().unwrap();
            assert!((n - 0.25).abs() < 1e-6, "expected 0.25, got {}", n);
        }
    }

    #[test]
    fn partition_helper_buckets_correctly() {
        let a = SvgAnimationNode::Animate {
            attribute_name: "opacity".into(),
            common: opacity(&["0", "1"], &[0.0, 1.0], 1.0),
        };
        let b = SvgAnimationNode::Animate {
            attribute_name: "display".into(),
            common: display(&["inline", "none"], &[0.0, 0.5], 1.0),
        };
        let c = SvgAnimationNode::Animate {
            attribute_name: "fill".into(),
            common: opacity(&["0", "1"], &[0.0, 1.0], 1.0),
        };
        let list = vec![a, b, c];
        let (displays, opacities) = partition(&list);
        assert_eq!(displays.len(), 1);
        assert_eq!(opacities.len(), 1);
    }

    #[test]
    fn keysplines_on_opacity_emit_warning() {
        let mut l = logs();
        let mut o = opacity(&["0", "1"], &[0.0, 1.0], 1.0);
        o.keyframes.key_splines = vec![crate::domain::BezierSpline {
            x1: 0.1,
            y1: 0.2,
            x2: 0.3,
            y2: 0.4,
        }];
        let d = display(&["inline", "none"], &[0.0, 0.5], 1.0);
        let _ = merge(&[&d], &[&o], &mut l).unwrap();
        let entries = l.into_entries();
        assert!(
            entries
                .iter()
                .any(|e| e.stage == "map.opacity_merge" && e.message.contains("keysplines")),
            "expected a keysplines warning"
        );
    }
}
