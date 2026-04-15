//! Port of `lib/src/data/parsers/svg_animation_parser.dart`.
//!
//! SMIL `<animate>` / `<animateTransform>` → `SvgAnimationNode`. Skips
//! unsupported nodes with a warning so one malformed animation doesn't
//! sink the whole document.

use once_cell::sync::Lazy;
use regex::Regex;
use roxmltree::Node;

use crate::domain::{
    BezierSpline, SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode,
    SvgKeyframes, SvgTransformKind,
};
use crate::log::LogCollector;

static WS_COMMA: Lazy<Regex> = Lazy::new(|| Regex::new(r"[ ,]+").unwrap());

pub fn parse(el: Node, parent: Option<Node>, logs: &mut LogCollector) -> Option<SvgAnimationNode> {
    match el.tag_name().name() {
        "animate" => parse_animate(el, parent, logs),
        "animateTransform" => parse_animate_transform(el, parent, logs),
        other => {
            logs.warn(
                "parse.anim",
                "skipping unsupported animation tag",
                &[
                    ("tag", other.into()),
                    (
                        "reason",
                        "MVP supports <animate> and <animateTransform> only".into(),
                    ),
                ],
            );
            None
        }
    }
}

fn parse_animate(el: Node, parent: Option<Node>, logs: &mut LogCollector) -> Option<SvgAnimationNode> {
    let attr = match el.attribute("attributeName") {
        Some(a) => a.to_string(),
        None => {
            logs.warn(
                "parse.anim",
                "skipping <animate> without attributeName",
                &[("xml", short(el).into())],
            );
            return None;
        }
    };
    let (dur, repeat) = parse_dur_and_repeat(el, logs)?;
    let keyframes = parse_keyframes(el, parent, logs)?;
    Some(SvgAnimationNode::Animate {
        attribute_name: attr,
        common: SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: repeat,
            additive: parse_additive(el),
            keyframes,
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        },
    })
}

fn parse_animate_transform(
    el: Node,
    parent: Option<Node>,
    logs: &mut LogCollector,
) -> Option<SvgAnimationNode> {
    let type_raw = match el.attribute("type") {
        Some(t) => t,
        None => {
            logs.warn(
                "parse.anim",
                "skipping <animateTransform> without type",
                &[("xml", short(el).into())],
            );
            return None;
        }
    };
    let kind = match type_raw {
        "translate" => SvgTransformKind::Translate,
        "scale" => SvgTransformKind::Scale,
        "rotate" => SvgTransformKind::Rotate,
        "skewX" => SvgTransformKind::SkewX,
        "skewY" => SvgTransformKind::SkewY,
        "matrix" => SvgTransformKind::Matrix,
        other => {
            logs.warn(
                "parse.anim",
                "skipping animateTransform with unknown type",
                &[("type", other.into())],
            );
            return None;
        }
    };
    let (dur, repeat) = parse_dur_and_repeat(el, logs)?;
    let keyframes = parse_keyframes(el, parent, logs)?;
    Some(SvgAnimationNode::AnimateTransform {
        kind,
        common: SvgAnimationCommon {
            dur_seconds: dur,
            repeat_indefinite: repeat,
            additive: parse_additive(el),
            keyframes,
            delay_seconds: 0.0,
            direction: Default::default(),
            fill_mode: Default::default(),
        },
    })
}

fn parse_dur_and_repeat(el: Node, logs: &mut LogCollector) -> Option<(f64, bool)> {
    let dur_raw = match el.attribute("dur") {
        Some(d) => d,
        None => {
            logs.warn(
                "parse.anim",
                "skipping animation without dur",
                &[("xml", short(el).into())],
            );
            return None;
        }
    };
    match parse_duration_seconds(dur_raw) {
        Some(dur) => {
            let repeat = el.attribute("repeatCount").unwrap_or("") == "indefinite";
            Some((dur, repeat))
        }
        None => {
            logs.warn(
                "parse.anim",
                "skipping animation with invalid dur",
                &[("dur", dur_raw.into())],
            );
            None
        }
    }
}

fn parse_additive(el: Node) -> SvgAnimationAdditive {
    if el.attribute("additive") == Some("sum") {
        SvgAnimationAdditive::Sum
    } else {
        SvgAnimationAdditive::Replace
    }
}

fn parse_keyframes(el: Node, parent: Option<Node>, logs: &mut LogCollector) -> Option<SvgKeyframes> {
    let values = if let Some(values_raw) = el.attribute("values") {
        values_raw
            .split(';')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
    } else {
        synthesize_from_to_by(el, parent, logs)?
    };

    let key_times = if let Some(kt_raw) = el.attribute("keyTimes") {
        let mut parsed = Vec::new();
        for part in kt_raw.split(';') {
            match part.trim().parse::<f64>() {
                Ok(n) => parsed.push(n),
                Err(e) => {
                    logs.warn(
                        "parse.anim",
                        "skipping animation with invalid keyTimes",
                        &[
                            ("keyTimes", kt_raw.into()),
                            ("err", e.to_string().into()),
                        ],
                    );
                    return None;
                }
            }
        }
        parsed
    } else {
        implicit_key_times(values.len())
    };

    if key_times.len() != values.len() {
        logs.warn(
            "parse.anim",
            "skipping animation with keyTimes/values mismatch",
            &[
                ("kt", (key_times.len() as u64).into()),
                ("v", (values.len() as u64).into()),
            ],
        );
        return None;
    }

    let calc_mode_raw = el.attribute("calcMode").unwrap_or("linear");
    let calc_mode = match calc_mode_raw {
        "linear" => Some(SvgAnimationCalcMode::Linear),
        "spline" => Some(SvgAnimationCalcMode::Spline),
        "discrete" => Some(SvgAnimationCalcMode::Discrete),
        "paced" => Some(SvgAnimationCalcMode::Paced),
        _ => {
            logs.warn(
                "parse.anim",
                "unknown calcMode, falling back to linear",
                &[("calcMode", calc_mode_raw.into())],
            );
            None
        }
    }
    .unwrap_or(SvgAnimationCalcMode::Linear);

    let mut key_splines = Vec::new();
    if let Some(splines_raw) = el.attribute("keySplines") {
        for entry in splines_raw.split(';') {
            let parts: Vec<&str> = WS_COMMA
                .split(entry.trim())
                .filter(|s| !s.is_empty())
                .collect();
            if parts.len() != 4 {
                continue;
            }
            let vals: Option<Vec<f64>> =
                parts.iter().map(|p| p.parse::<f64>().ok()).collect();
            if let Some(v) = vals {
                key_splines.push(BezierSpline {
                    x1: v[0],
                    y1: v[1],
                    x2: v[2],
                    y2: v[3],
                });
            }
        }
    }

    Some(SvgKeyframes {
        key_times,
        values,
        calc_mode,
        key_splines,
    })
}

fn implicit_key_times(n: usize) -> Vec<f64> {
    if n <= 1 {
        return vec![0.0];
    }
    (0..n).map(|i| i as f64 / (n - 1) as f64).collect()
}

fn synthesize_from_to_by(
    el: Node,
    parent: Option<Node>,
    logs: &mut LogCollector,
) -> Option<Vec<String>> {
    let from = el.attribute("from").map(|s| s.trim().to_string());
    let to = el.attribute("to").map(|s| s.trim().to_string());
    let by = el.attribute("by").map(|s| s.trim().to_string());

    if let (Some(f), Some(t)) = (from.clone(), to.clone()) {
        return Some(vec![f, t]);
    }
    if let (Some(f), Some(b)) = (from.clone(), by.clone()) {
        if let Some(sum) = add_numeric_lists(&f, &b) {
            return Some(vec![f, sum]);
        }
        logs.warn(
            "parse.anim",
            "by sugar requires numeric from/by",
            &[("from", f.into()), ("by", b.into())],
        );
        return None;
    }
    if let Some(t) = to.clone() {
        let attr_name = el.attribute("attributeName");
        if let (Some(parent), Some(attr_name)) = (parent, attr_name) {
            if let Some(base) = parent.attribute(attr_name) {
                let base = base.trim();
                if !base.is_empty() {
                    return Some(vec![base.to_string(), t]);
                }
            }
        }
        return Some(vec![t.clone(), t]);
    }
    if let Some(b) = by {
        logs.warn(
            "parse.anim",
            "by without from is not resolvable",
            &[("by", b.into())],
        );
        return None;
    }
    logs.warn(
        "parse.anim",
        "skipping animation without values= or from/to/by",
        &[("xml", short(el).into())],
    );
    None
}

fn add_numeric_lists(a: &str, b: &str) -> Option<String> {
    let a_parts: Vec<&str> = WS_COMMA.split(a).filter(|s| !s.is_empty()).collect();
    let b_parts: Vec<&str> = WS_COMMA.split(b).filter(|s| !s.is_empty()).collect();
    if a_parts.len() != b_parts.len() || a_parts.is_empty() {
        return None;
    }
    let mut out = Vec::with_capacity(a_parts.len());
    for i in 0..a_parts.len() {
        let x: f64 = a_parts[i].parse().ok()?;
        let y: f64 = b_parts[i].parse().ok()?;
        out.push(fmt_num(x + y));
    }
    Some(out.join(" "))
}

fn fmt_num(v: f64) -> String {
    if v == v.round() {
        format!("{:.0}", v)
    } else {
        v.to_string()
    }
}

fn parse_duration_seconds(raw: &str) -> Option<f64> {
    let t = raw.trim();
    if let Some(ms) = t.strip_suffix("ms") {
        return ms.parse::<f64>().ok().map(|v| v / 1000.0);
    }
    if let Some(s) = t.strip_suffix('s') {
        return s.parse::<f64>().ok();
    }
    t.parse::<f64>().ok()
}

fn short(el: Node) -> String {
    format!("<{}>", el.tag_name().name())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;
    use roxmltree::Document;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn first_anim(xml: &str) -> (Document<'_>, &'_ str) {
        (Document::parse(xml).unwrap(), "stub")
    }

    #[test]
    fn animate_opacity_0_to_1() {
        let xml = r#"<animate attributeName="opacity" dur="1s" values="0;1"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).expect("parsed");
        let (attr, common) = match a {
            SvgAnimationNode::Animate { attribute_name, common } => (attribute_name, common),
            _ => panic!("expected Animate"),
        };
        assert_eq!(attr, "opacity");
        assert_eq!(common.dur_seconds, 1.0);
        assert!(!common.repeat_indefinite);
        assert_eq!(common.keyframes.values, vec!["0", "1"]);
        assert_eq!(common.keyframes.key_times, vec![0.0, 1.0]);
    }

    #[test]
    fn animate_requires_attribute_name() {
        let xml = r#"<animate dur="1s" values="0;1"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        assert!(parse(doc.root_element(), None, &mut logs).is_none());
    }

    #[test]
    fn animate_requires_dur() {
        let xml = r#"<animate attributeName="opacity" values="0;1"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        assert!(parse(doc.root_element(), None, &mut logs).is_none());
    }

    #[test]
    fn dur_ms_is_converted_to_seconds() {
        let xml = r#"<animate attributeName="x" dur="500ms" values="0;1"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).unwrap();
        if let SvgAnimationNode::Animate { common, .. } = a {
            assert!((common.dur_seconds - 0.5).abs() < 1e-9);
        }
    }

    #[test]
    fn repeat_indefinite() {
        let xml = r#"<animate attributeName="x" dur="1s" values="0;1" repeatCount="indefinite"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).unwrap();
        if let SvgAnimationNode::Animate { common, .. } = a {
            assert!(common.repeat_indefinite);
        }
    }

    #[test]
    fn keytimes_must_match_values() {
        let xml = r#"<animate attributeName="x" dur="1s" values="0;1;2" keyTimes="0;1"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        assert!(parse(doc.root_element(), None, &mut logs).is_none());
    }

    #[test]
    fn calc_mode_spline_with_key_splines() {
        let xml = r#"<animate attributeName="x" dur="1s" values="0;1" calcMode="spline" keySplines="0.1 0.2 0.3 0.4"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).unwrap();
        if let SvgAnimationNode::Animate { common, .. } = a {
            assert_eq!(common.keyframes.calc_mode, SvgAnimationCalcMode::Spline);
            assert_eq!(common.keyframes.key_splines.len(), 1);
            assert_eq!(common.keyframes.key_splines[0].x1, 0.1);
        }
    }

    #[test]
    fn from_to_synthesises_two_frames() {
        let xml = r#"<animate attributeName="x" dur="1s" from="0" to="10"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).unwrap();
        if let SvgAnimationNode::Animate { common, .. } = a {
            assert_eq!(common.keyframes.values, vec!["0", "10"]);
        }
    }

    #[test]
    fn from_by_adds_component_wise() {
        let xml = r#"<animate attributeName="x" dur="1s" from="1 2" by="3 4"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).unwrap();
        if let SvgAnimationNode::Animate { common, .. } = a {
            assert_eq!(common.keyframes.values, vec!["1 2", "4 6"]);
        }
    }

    #[test]
    fn animate_transform_translate() {
        let xml = r#"<animateTransform attributeName="transform" type="translate" dur="2s" values="0 0;10 20"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        let a = parse(doc.root_element(), None, &mut logs).unwrap();
        if let SvgAnimationNode::AnimateTransform { kind, common } = a {
            assert_eq!(kind, SvgTransformKind::Translate);
            assert_eq!(common.dur_seconds, 2.0);
        } else {
            panic!("expected AnimateTransform");
        }
    }

    #[test]
    fn unsupported_animation_tag_is_skipped() {
        let xml = r#"<set attributeName="x" to="1"/>"#;
        let doc = Document::parse(xml).unwrap();
        let mut logs = mk_logs();
        assert!(parse(doc.root_element(), None, &mut logs).is_none());
    }

    // Silence unused warning for the helper we left in place for future tests.
    #[test]
    fn _touch_helpers() {
        let (_, _) = first_anim("<x/>");
    }
}
