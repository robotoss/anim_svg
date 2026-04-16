//! Port of `lib/src/data/parsers/svg_svgator_parser.dart`.
//!
//! Parses the JSON payload that the Svgator exporter emits inside a `<script>`
//! tag alongside the SVG geometry, e.g.:
//!
//! ```text
//!   (function(s,i,u,o,c,...){...})(
//!       '91c80d77',
//!       {"root":"...","animations":[{"elements":{...}}],...},
//!       'https://cdn.svgator.com/ply/',
//!       ...);
//! ```
//!
//! We pull out the **second** positional argument (the `i` object literal) and
//! translate per-element keyframe tracks into the same `SvgAnimationNode` /
//! `SvgStaticTransform` shapes the SMIL and CSS parsers produce.
//!
//! Scope today: every property observed in Svgator exports (`d`, `opacity`,
//! `fill-opacity`, `stroke-dashoffset`, `stroke-dasharray`,
//! `transform.data/keys` → translate/scale/rotate/origin). Animated gradient
//! `fill` is parsed-but-skipped with a warn — the shape mapper has no string
//! contract for gradient-over-time, and the static gradient still renders via
//! the `<defs>` pipeline.

use std::collections::HashMap;

use serde_json::Value;

use crate::domain::{
    BezierSpline, SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode,
    SvgKeyframes, SvgStaticTransform, SvgTransformKind,
};
use crate::log::LogCollector;

/// Output of [`parse`]: two maps keyed by SVG element id.
#[derive(Debug, Default)]
pub struct SvgatorTracks {
    pub animations: HashMap<String, Vec<SvgAnimationNode>>,
    pub static_transforms: HashMap<String, Vec<SvgStaticTransform>>,
}

/// Parses the concatenated text of all `<script>` blocks found inside the SVG
/// document. Returns empty maps when no Svgator payload is present.
pub fn parse(script_text: &str, logs: &mut LogCollector) -> SvgatorTracks {
    let mut out = SvgatorTracks::default();
    if script_text.trim().is_empty() {
        return out;
    }

    let payload = match extract_payload(script_text, logs) {
        Some(p) => p,
        None => return out,
    };

    let anims_list = match payload.get("animations").and_then(|v| v.as_array()) {
        Some(a) => a,
        None => {
            logs.warn("parse.svgator", "payload has no animations array", &[]);
            return out;
        }
    };

    let mut total_tracks: usize = 0;
    let mut total_elements: usize = 0;

    for group in anims_list {
        let elements = match group.get("elements").and_then(|v| v.as_object()) {
            Some(e) => e,
            None => continue,
        };
        for (element_id, props) in elements {
            if element_id.is_empty() {
                continue;
            }
            let props = match props.as_object() {
                Some(p) => p,
                None => continue,
            };
            total_elements += 1;
            let (anims, statics) = parse_element(element_id, props, logs);
            if !anims.is_empty() {
                total_tracks += anims.len();
                out.animations
                    .entry(element_id.clone())
                    .or_default()
                    .extend(anims);
            }
            if !statics.is_empty() {
                out.static_transforms
                    .entry(element_id.clone())
                    .or_default()
                    .extend(statics);
            }
        }
    }

    logs.info(
        "parse.svgator",
        "payload extracted",
        &[
            ("elements", (total_elements as u64).into()),
            ("tracks", (total_tracks as u64).into()),
        ],
    );

    out
}

/// Locates the Svgator JSON literal inside the IIFE argument list. The
/// exporter uses a well-known boilerplate: the first positional argument is
/// a short hash string in single quotes, the second is an object literal
/// holding the animation data, followed by the CDN URL `'https://.../ply/'`.
/// We anchor on that URL to guarantee we parsed the right exporter.
fn extract_payload(source: &str, logs: &mut LogCollector) -> Option<serde_json::Map<String, Value>> {
    // We work on byte indices because the source is ASCII-ish JS and JSON;
    // non-ASCII chars only legally appear inside string literals and the brace
    // balancer already tolerates that.
    let bytes = source.as_bytes();
    let cdn_idx = match source.find("'https://cdn.svgator.com") {
        Some(i) => i,
        None => {
            logs.debug("parse.svgator", "no svgator payload marker found", &[]);
            return None;
        }
    };

    // Scan backward from the CDN URL to find the opening '{' of the JSON
    // object argument; skip whitespace and commas between arguments.
    let mut i = cdn_idx as isize - 1;
    while i >= 0 {
        let c = bytes[i as usize];
        if c == b' ' || c == b',' || c == b'\n' || c == b'\t' || c == b'\r' {
            i -= 1;
        } else {
            break;
        }
    }
    if i < 0 || bytes[i as usize] != b'}' {
        logs.warn("parse.svgator", "payload not terminated by }", &[]);
        return None;
    }
    let end = (i + 1) as usize;

    // Balance-match backward to find the paired '{'.
    let mut depth: i32 = 0;
    let mut start: isize = -1;
    let mut in_string = false;
    let mut quote: u8 = 0;
    let mut j: isize = end as isize - 1;
    while j >= 0 {
        let c = bytes[j as usize];
        if in_string {
            if c == quote && (j == 0 || bytes[(j - 1) as usize] != b'\\') {
                in_string = false;
                quote = 0;
            }
            j -= 1;
            continue;
        }
        if c == b'"' || c == b'\'' {
            in_string = true;
            quote = c;
            j -= 1;
            continue;
        }
        if c == b'}' {
            depth += 1;
        }
        if c == b'{' {
            depth -= 1;
            if depth == 0 {
                start = j;
                break;
            }
        }
        j -= 1;
    }
    if start < 0 {
        logs.warn("parse.svgator", "could not balance { } in payload", &[]);
        return None;
    }

    let raw = &source[start as usize..end];
    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Object(m)) => Some(m),
        Ok(_) => {
            logs.warn("parse.svgator", "payload is not a JSON object", &[]);
            None
        }
        Err(e) => {
            logs.warn(
                "parse.svgator",
                "payload JSON parse failed",
                &[("err", e.to_string().into())],
            );
            None
        }
    }
}

fn parse_element(
    id: &str,
    props: &serde_json::Map<String, Value>,
    logs: &mut LogCollector,
) -> (Vec<SvgAnimationNode>, Vec<SvgStaticTransform>) {
    let mut anims: Vec<SvgAnimationNode> = Vec::new();
    let mut statics: Vec<SvgStaticTransform> = Vec::new();

    for (key, value) in props {
        match key.as_str() {
            "d" => {
                if let Some(a) = parse_path_track(id, value, logs) {
                    anims.push(a);
                }
            }
            "opacity" | "fill-opacity" | "stroke-dashoffset" => {
                if let Some(a) = parse_scalar_track(id, key, value, logs) {
                    anims.push(a);
                }
            }
            "stroke-dasharray" => {
                if let Some(a) = parse_vector_track(id, key, value, logs) {
                    anims.push(a);
                }
            }
            "fill" => {
                logs.warn(
                    "parse.svgator",
                    "animated fill (gradient) not yet supported → static fallback",
                    &[("id", id.into())],
                );
            }
            "transform" => {
                if let Some(map) = value.as_object() {
                    parse_transform(id, map, &mut anims, &mut statics, logs);
                }
            }
            other => {
                logs.debug(
                    "parse.svgator",
                    "skipping unknown property",
                    &[("id", id.into()), ("prop", other.into())],
                );
            }
        }
    }

    (anims, statics)
}

// ───────────────────────────── scalar / vector / path tracks

fn parse_scalar_track(
    id: &str,
    attr: &str,
    value: &Value,
    logs: &mut LogCollector,
) -> Option<SvgAnimationNode> {
    let frames = coerce_frames(value)?;
    if frames.len() < 2 {
        if frames.len() == 1 {
            logs.debug(
                "parse.svgator",
                "single-frame scalar → skipping",
                &[("id", id.into()), ("attr", attr.into())],
            );
        }
        return None;
    }
    let mut values = Vec::with_capacity(frames.len());
    for f in &frames {
        let v = f.get("v");
        match v.and_then(|x| x.as_f64()) {
            Some(n) => values.push(fmt(n)),
            None => {
                logs.warn(
                    "parse.svgator",
                    "non-numeric scalar keyframe → skip track",
                    &[("id", id.into()), ("attr", attr.into())],
                );
                return None;
            }
        }
    }
    Some(build_animate(attr, &frames, values))
}

fn parse_vector_track(
    id: &str,
    attr: &str,
    value: &Value,
    logs: &mut LogCollector,
) -> Option<SvgAnimationNode> {
    let frames = coerce_frames(value)?;
    if frames.len() < 2 {
        return None;
    }
    let mut values = Vec::with_capacity(frames.len());
    for f in &frames {
        let v = f.get("v").and_then(|x| x.as_array());
        let arr = match v {
            Some(a) => a,
            None => {
                logs.warn(
                    "parse.svgator",
                    "non-list vector keyframe → skip track",
                    &[("id", id.into()), ("attr", attr.into())],
                );
                return None;
            }
        };
        let joined = arr
            .iter()
            .filter_map(|n| n.as_f64())
            .map(fmt)
            .collect::<Vec<_>>()
            .join(",");
        values.push(joined);
    }
    Some(build_animate(attr, &frames, values))
}

fn parse_path_track(id: &str, value: &Value, logs: &mut LogCollector) -> Option<SvgAnimationNode> {
    let frames = coerce_frames(value)?;
    if frames.len() < 2 {
        return None;
    }
    let mut values = Vec::with_capacity(frames.len());
    for f in &frames {
        let v = f.get("v").and_then(|x| x.as_array());
        let arr = match v {
            Some(a) => a,
            None => {
                logs.warn(
                    "parse.svgator",
                    "path keyframe is not a list → skip track",
                    &[("id", id.into())],
                );
                return None;
            }
        };
        match serialize_path(arr) {
            Some(s) => values.push(s),
            None => {
                logs.warn(
                    "parse.svgator",
                    "path keyframe serialization failed → skip",
                    &[("id", id.into())],
                );
                return None;
            }
        }
    }
    Some(build_animate("d", &frames, values))
}

// ───────────────────────────── transform block (data + keys)

fn parse_transform(
    id: &str,
    transform: &serde_json::Map<String, Value>,
    anims: &mut Vec<SvgAnimationNode>,
    statics: &mut Vec<SvgStaticTransform>,
    logs: &mut LogCollector,
) {
    let data = transform.get("data").and_then(|v| v.as_object());
    let keys = transform.get("keys").and_then(|v| v.as_object());

    let static_t = data.and_then(|d| read_xy(d.get("t")));
    let static_o = data.and_then(|d| read_xy(d.get("o")));
    let static_r = data.and_then(|d| read_num(d.get("r")));

    let anim_t = keys.and_then(|k| k.get("t")).and_then(coerce_frames);
    let anim_o = keys.and_then(|k| k.get("o")).and_then(coerce_frames);
    let anim_s = keys.and_then(|k| k.get("s")).and_then(coerce_frames);
    let anim_r = keys.and_then(|k| k.get("r")).and_then(coerce_frames);

    // Translate (position). Prefer animated keys.t; else emit static data.t.
    // When neither is present but keys.o is animated, keys.o maps to position
    // (Svgator's transform-origin animation doubles as world-space placement).
    if let Some(ref frames) = anim_t {
        if frames.len() >= 2 {
            if let Some(vals) = xy_values(frames, logs, id, "transform.t") {
                anims.push(SvgAnimationNode::AnimateTransform {
                    kind: SvgTransformKind::Translate,
                    common: SvgAnimationCommon {
                        dur_seconds: dur_of(frames),
                        repeat_indefinite: true,
                        additive: SvgAnimationAdditive::Replace,
                        keyframes: keyframes(frames, vals),
                        delay_seconds: delay_of(frames),
                        direction: Default::default(),
                        fill_mode: Default::default(),
                    },
                });
            }
        }
    } else if let Some(ref frames) = anim_o {
        if frames.len() >= 2 {
            if let Some(vals) = xy_values(frames, logs, id, "transform.o") {
                anims.push(SvgAnimationNode::AnimateTransform {
                    kind: SvgTransformKind::Translate,
                    common: SvgAnimationCommon {
                        dur_seconds: dur_of(frames),
                        repeat_indefinite: true,
                        additive: SvgAnimationAdditive::Replace,
                        keyframes: keyframes(frames, vals),
                        delay_seconds: delay_of(frames),
                        direction: Default::default(),
                        fill_mode: Default::default(),
                    },
                });
            }
        }
    } else if let Some((x, y)) = static_t {
        statics.push(SvgStaticTransform {
            kind: SvgTransformKind::Translate,
            values: vec![x, y],
        });
    } else if let Some((x, y)) = static_o {
        statics.push(SvgStaticTransform {
            kind: SvgTransformKind::Translate,
            values: vec![x, y],
        });
    }

    // Scale.
    if let Some(ref frames) = anim_s {
        if frames.len() >= 2 {
            if let Some(vals) = xy_values(frames, logs, id, "transform.s") {
                anims.push(SvgAnimationNode::AnimateTransform {
                    kind: SvgTransformKind::Scale,
                    common: SvgAnimationCommon {
                        dur_seconds: dur_of(frames),
                        repeat_indefinite: true,
                        additive: SvgAnimationAdditive::Replace,
                        keyframes: keyframes(frames, vals),
                        delay_seconds: delay_of(frames),
                        direction: Default::default(),
                        fill_mode: Default::default(),
                    },
                });
            }
        }
    }

    // Rotate.
    let mut rotate_emitted = false;
    if let Some(ref frames) = anim_r {
        if frames.len() >= 2 {
            let mut vals: Vec<String> = Vec::with_capacity(frames.len());
            let mut ok = true;
            for f in frames {
                match f.get("v").and_then(|x| x.as_f64()) {
                    Some(n) => vals.push(fmt(n)),
                    None => {
                        logs.warn(
                            "parse.svgator",
                            "non-numeric rotate keyframe → skip track",
                            &[("id", id.into())],
                        );
                        ok = false;
                        break;
                    }
                }
            }
            if ok && vals.len() == frames.len() {
                anims.push(SvgAnimationNode::AnimateTransform {
                    kind: SvgTransformKind::Rotate,
                    common: SvgAnimationCommon {
                        dur_seconds: dur_of(frames),
                        repeat_indefinite: true,
                        additive: SvgAnimationAdditive::Replace,
                        keyframes: keyframes(frames, vals),
                        delay_seconds: delay_of(frames),
                        direction: Default::default(),
                        fill_mode: Default::default(),
                    },
                });
                rotate_emitted = true;
            }
        }
    }
    if !rotate_emitted {
        if anim_r.as_ref().map(|f| f.len() >= 2).unwrap_or(false) {
            // animated rotate was attempted but failed validation; don't emit static fallback
        } else if let Some(r) = static_r {
            if r != 0.0 {
                statics.push(SvgStaticTransform {
                    kind: SvgTransformKind::Rotate,
                    values: vec![r, 0.0, 0.0],
                });
            }
        }
    }

    // Pivot compensation: when scale or rotate is animated but `keys.o` is
    // not, emit a constant `additive=sum` translate whose value is the static
    // origin. transform_mapper sign-flips it onto Lottie's anchor, so
    // rotation/scale pivot around `data.o` instead of around (0,0).
    let needs_pivot = anim_s.as_ref().map(|f| f.len() >= 2).unwrap_or(false)
        || anim_r.as_ref().map(|f| f.len() >= 2).unwrap_or(false);
    let anim_origin_handled = anim_o.as_ref().map(|f| f.len() >= 2).unwrap_or(false);
    if needs_pivot && !anim_origin_handled {
        if let Some((ox, oy)) = static_o {
            let v = format!("{},{}", fmt(-ox), fmt(-oy));
            anims.push(SvgAnimationNode::AnimateTransform {
                kind: SvgTransformKind::Translate,
                common: SvgAnimationCommon {
                    dur_seconds: 0.001,
                    repeat_indefinite: true,
                    additive: SvgAnimationAdditive::Sum,
                    keyframes: SvgKeyframes {
                        key_times: vec![0.0, 1.0],
                        values: vec![v.clone(), v],
                        calc_mode: SvgAnimationCalcMode::Linear,
                        key_splines: vec![BezierSpline {
                            x1: 0.0,
                            y1: 0.0,
                            x2: 1.0,
                            y2: 1.0,
                        }],
                    },
                    delay_seconds: 0.0,
                    direction: Default::default(),
                    fill_mode: Default::default(),
                },
            });
        }
    }
}

// ───────────────────────────── helpers

/// Frame type — Svgator frames are objects with `t` (ms time) plus payload.
type Frame = serde_json::Map<String, Value>;

fn coerce_frames(raw: &Value) -> Option<Vec<Frame>> {
    let arr = raw.as_array()?;
    let mut out: Vec<Frame> = Vec::new();
    for f in arr {
        if let Some(obj) = f.as_object() {
            if obj.get("t").and_then(|v| v.as_f64()).is_some() {
                out.push(obj.clone());
            }
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn read_xy(raw: Option<&Value>) -> Option<(f64, f64)> {
    let obj = raw?.as_object()?;
    let x = obj.get("x")?.as_f64()?;
    let y = obj.get("y")?.as_f64()?;
    Some((x, y))
}

fn read_num(raw: Option<&Value>) -> Option<f64> {
    raw?.as_f64()
}

fn dur_of(frames: &[Frame]) -> f64 {
    let min_t = frames.first().unwrap().get("t").unwrap().as_f64().unwrap();
    let max_t = frames.last().unwrap().get("t").unwrap().as_f64().unwrap();
    let span = (max_t - min_t) / 1000.0;
    if span > 0.0 {
        span
    } else {
        0.001
    }
}

fn delay_of(frames: &[Frame]) -> f64 {
    let min_t = frames.first().unwrap().get("t").unwrap().as_f64().unwrap();
    if min_t > 0.0 {
        min_t / 1000.0
    } else {
        0.0
    }
}

/// Builds `SvgKeyframes` with normalized `[0..1]` times, spline easing
/// collected from per-frame `e:[x1,y1,x2,y2]` (linear when absent), and the
/// caller-provided serialized value strings.
fn keyframes(frames: &[Frame], values: Vec<String>) -> SvgKeyframes {
    let min_t = frames.first().unwrap().get("t").unwrap().as_f64().unwrap();
    let max_t = frames.last().unwrap().get("t").unwrap().as_f64().unwrap();
    let span = max_t - min_t;
    let mut key_times = Vec::with_capacity(frames.len());
    for f in frames {
        let t = f.get("t").unwrap().as_f64().unwrap();
        key_times.push(if span > 0.0 { (t - min_t) / span } else { 0.0 });
    }
    let mut splines = Vec::with_capacity(frames.len().saturating_sub(1));
    for i in 0..frames.len().saturating_sub(1) {
        let e = frames[i].get("e").and_then(|v| v.as_array());
        let spline = match e {
            Some(arr) if arr.len() >= 4 => {
                let x1 = arr[0].as_f64();
                let y1 = arr[1].as_f64();
                let x2 = arr[2].as_f64();
                let y2 = arr[3].as_f64();
                match (x1, y1, x2, y2) {
                    (Some(x1), Some(y1), Some(x2), Some(y2)) => BezierSpline { x1, y1, x2, y2 },
                    _ => BezierSpline {
                        x1: 0.0,
                        y1: 0.0,
                        x2: 1.0,
                        y2: 1.0,
                    },
                }
            }
            _ => BezierSpline {
                x1: 0.0,
                y1: 0.0,
                x2: 1.0,
                y2: 1.0,
            },
        };
        splines.push(spline);
    }
    SvgKeyframes {
        key_times,
        values,
        calc_mode: SvgAnimationCalcMode::Spline,
        key_splines: splines,
    }
}

fn build_animate(attr: &str, frames: &[Frame], values: Vec<String>) -> SvgAnimationNode {
    SvgAnimationNode::Animate {
        attribute_name: attr.to_string(),
        common: SvgAnimationCommon {
            dur_seconds: dur_of(frames),
            repeat_indefinite: true,
            additive: SvgAnimationAdditive::Replace,
            keyframes: keyframes(frames, values),
            delay_seconds: delay_of(frames),
            direction: Default::default(),
            fill_mode: Default::default(),
        },
    }
}

/// Extracts `"x,y"` values from keyframes whose `v` is `{x,y}`. Returns
/// `None` (caller skips track) if any frame has a malformed `v`.
fn xy_values(
    frames: &[Frame],
    logs: &mut LogCollector,
    id: &str,
    attr: &str,
) -> Option<Vec<String>> {
    let mut out = Vec::with_capacity(frames.len());
    for f in frames {
        match read_xy(f.get("v")) {
            Some((x, y)) => out.push(format!("{},{}", fmt(x), fmt(y))),
            None => {
                logs.warn(
                    "parse.svgator",
                    "malformed xy keyframe → skip track",
                    &[("id", id.into()), ("attr", attr.into())],
                );
                return None;
            }
        }
    }
    Some(out)
}

/// Serializes a Svgator path-command array back to an SVG path string. The
/// array alternates between a string command letter (`M`, `L`, `C`, `Z`,
/// etc.) and its numeric arguments, e.g.
/// `["M", 10, 20, "L", 30, 40, "Z"]` → `"M 10 20 L 30 40 Z"`.
fn serialize_path(cmds: &[Value]) -> Option<String> {
    let mut buf = String::new();
    let mut i = 0usize;
    while i < cmds.len() {
        let tok = cmds[i].as_str()?;
        if !buf.is_empty() {
            buf.push(' ');
        }
        buf.push_str(tok);
        i += 1;
        while i < cmds.len() {
            if let Some(n) = cmds[i].as_f64() {
                buf.push(' ');
                buf.push_str(&fmt(n));
                i += 1;
            } else {
                break;
            }
        }
    }
    Some(buf)
}

fn fmt(v: f64) -> String {
    if v.is_nan() || v.is_infinite() {
        return "0".to_string();
    }
    if v == v.round() && v.abs() < 1e15 {
        format!("{:.0}", v)
    } else {
        v.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Debug)
    }

    /// Wraps a raw JSON blob in the IIFE boilerplate the parser expects.
    fn wrap(json: &str) -> String {
        format!(
            "(function(s,i,u){{}})('abc123',{},'https://cdn.svgator.com/ply/');",
            json
        )
    }

    #[test]
    fn minimal_payload_parses_expected_animation_count() {
        let payload = r#"{
            "animations":[{"elements":{
                "el1":{
                    "opacity":[{"t":0,"v":0},{"t":1000,"v":1}]
                },
                "el2":{
                    "d":[
                        {"t":0,"v":["M",0,0,"L",10,10]},
                        {"t":500,"v":["M",0,0,"L",20,20]}
                    ]
                }
            }}]
        }"#;
        let script = wrap(payload);
        let mut logs = mk_logs();
        let out = parse(&script, &mut logs);
        assert_eq!(out.animations.len(), 2);
        let el1 = &out.animations["el1"];
        assert_eq!(el1.len(), 1);
        match &el1[0] {
            SvgAnimationNode::Animate {
                attribute_name,
                common,
            } => {
                assert_eq!(attribute_name, "opacity");
                assert_eq!(common.keyframes.values, vec!["0", "1"]);
                assert_eq!(common.dur_seconds, 1.0);
            }
            _ => panic!("expected Animate"),
        }
    }

    #[test]
    fn unknown_property_is_debug_logged_and_skipped() {
        let payload = r#"{
            "animations":[{"elements":{
                "el":{
                    "made-up":[{"t":0,"v":0},{"t":1000,"v":1}]
                }
            }}]
        }"#;
        let mut logs = mk_logs();
        let out = parse(&wrap(payload), &mut logs);
        assert!(out.animations.is_empty());
        let entries = logs.into_entries();
        let found = entries.iter().any(|e| {
            e.message == "skipping unknown property"
                && e.fields.get("prop").and_then(|v| v.as_str()) == Some("made-up")
        });
        assert!(found, "expected debug log for unknown property");
    }

    #[test]
    fn malformed_json_errors_gracefully() {
        // Unbalanced brace inside the payload position — extract_payload gets
        // text but JSON parse fails.
        let script = "(function(){})('h', {\"animations\": [,,,}, 'https://cdn.svgator.com/ply/');";
        let mut logs = mk_logs();
        let out = parse(script, &mut logs);
        assert!(out.animations.is_empty());
        let entries = logs.into_entries();
        assert!(
            entries.iter().any(|e| e.message.contains("JSON parse failed")
                || e.message.contains("could not balance")),
            "expected JSON failure warn, got {:?}",
            entries
        );
    }

    #[test]
    fn transform_kind_mapping() {
        let payload = r#"{
            "animations":[{"elements":{
                "el":{
                    "transform":{
                        "data":{"t":{"x":1,"y":2},"o":{"x":5,"y":5},"r":0},
                        "keys":{
                            "s":[
                                {"t":0,"v":{"x":1,"y":1}},
                                {"t":1000,"v":{"x":2,"y":2}}
                            ],
                            "r":[
                                {"t":0,"v":0},
                                {"t":1000,"v":360}
                            ]
                        }
                    }
                }
            }}]
        }"#;
        let mut logs = mk_logs();
        let out = parse(&wrap(payload), &mut logs);
        let anims = &out.animations["el"];
        let kinds: Vec<SvgTransformKind> = anims
            .iter()
            .filter_map(|a| match a {
                SvgAnimationNode::AnimateTransform { kind, .. } => Some(*kind),
                _ => None,
            })
            .collect();
        assert!(kinds.contains(&SvgTransformKind::Scale));
        assert!(kinds.contains(&SvgTransformKind::Rotate));
        // Pivot compensation: scale+rotate animated with static origin → extra sum translate.
        let sum_translates = anims
            .iter()
            .filter(|a| matches!(a, SvgAnimationNode::AnimateTransform {
                kind: SvgTransformKind::Translate, common
            } if matches!(common.additive, SvgAnimationAdditive::Sum)))
            .count();
        assert_eq!(sum_translates, 1, "expected one pivot-compensation translate");
    }

    #[test]
    fn keyframe_time_conversion_normalizes_and_sets_delay() {
        let payload = r#"{
            "animations":[{"elements":{
                "el":{
                    "opacity":[
                        {"t":500,"v":0},
                        {"t":1500,"v":0.5},
                        {"t":2500,"v":1}
                    ]
                }
            }}]
        }"#;
        let mut logs = mk_logs();
        let out = parse(&wrap(payload), &mut logs);
        let a = &out.animations["el"][0];
        match a {
            SvgAnimationNode::Animate { common, .. } => {
                // dur = (2500 - 500) / 1000 = 2.0, delay = 500 / 1000 = 0.5
                assert!((common.dur_seconds - 2.0).abs() < 1e-9);
                assert!((common.delay_seconds - 0.5).abs() < 1e-9);
                // times are renormalized to [0,1] over the span
                let kt = &common.keyframes.key_times;
                assert_eq!(kt.len(), 3);
                assert!((kt[0] - 0.0).abs() < 1e-9);
                assert!((kt[1] - 0.5).abs() < 1e-9);
                assert!((kt[2] - 1.0).abs() < 1e-9);
            }
            _ => panic!("expected Animate"),
        }
    }

    #[test]
    fn missing_fields_logged_and_skipped() {
        // Scalar track where one frame has a non-numeric value: whole track is skipped
        // with a warn.
        let payload = r#"{
            "animations":[{"elements":{
                "el":{
                    "opacity":[
                        {"t":0,"v":0},
                        {"t":1000,"v":"oops"}
                    ]
                }
            }}]
        }"#;
        let mut logs = mk_logs();
        let out = parse(&wrap(payload), &mut logs);
        assert!(
            out.animations.get("el").map(|v| v.is_empty()).unwrap_or(true),
            "track with bad frame should not produce an animation"
        );
        let entries = logs.into_entries();
        assert!(
            entries
                .iter()
                .any(|e| e.message.contains("non-numeric scalar")),
            "expected warn for non-numeric scalar, got {:?}",
            entries
        );
    }

    #[test]
    fn no_payload_marker_returns_empty() {
        let mut logs = mk_logs();
        let out = parse("console.log('unrelated')", &mut logs);
        assert!(out.animations.is_empty());
        assert!(out.static_transforms.is_empty());
    }

    #[test]
    fn static_transforms_emitted_when_no_animation() {
        let payload = r#"{
            "animations":[{"elements":{
                "el":{
                    "transform":{
                        "data":{"t":{"x":10,"y":20},"r":45}
                    }
                }
            }}]
        }"#;
        let mut logs = mk_logs();
        let out = parse(&wrap(payload), &mut logs);
        let st = &out.static_transforms["el"];
        let has_translate = st
            .iter()
            .any(|s| s.kind == SvgTransformKind::Translate && s.values == vec![10.0, 20.0]);
        let has_rotate = st
            .iter()
            .any(|s| s.kind == SvgTransformKind::Rotate && s.values == vec![45.0, 0.0, 0.0]);
        assert!(has_translate);
        assert!(has_rotate);
    }

    #[test]
    fn serialize_path_formats_ints_without_decimal() {
        let cmds = vec![
            Value::String("M".into()),
            Value::from(0),
            Value::from(0),
            Value::String("L".into()),
            Value::from(10.5),
            Value::from(20),
            Value::String("Z".into()),
        ];
        let out = serialize_path(&cmds).unwrap();
        assert_eq!(out, "M 0 0 L 10.5 20 Z");
    }
}
