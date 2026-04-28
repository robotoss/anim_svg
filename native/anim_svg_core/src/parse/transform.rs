//! Port of `lib/src/data/parsers/svg_transform_parser.dart`.
//!
//! Parses the SVG `transform="..."` attribute into a flat list of
//! `SvgStaticTransform`. Unknown functions are warned-about and skipped
//! so the rest of the chain still applies.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::domain::{SvgStaticTransform, SvgTransformKind};
use crate::log::LogCollector;

static FN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(\w+)\s*\(([^)]*)\)").unwrap());
static NUM_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?").unwrap()
});

pub fn parse(raw: Option<&str>, logs: &mut LogCollector) -> Vec<SvgStaticTransform> {
    let Some(raw) = raw else { return Vec::new() };
    if raw.trim().is_empty() {
        return Vec::new();
    }

    let mut out = Vec::new();
    for caps in FN_RE.captures_iter(raw) {
        let name = caps.get(1).map(|m| m.as_str()).unwrap_or("");
        let args_raw = caps.get(2).map(|m| m.as_str()).unwrap_or("");
        let args = tokenize_numbers(args_raw);

        match name {
            "translate" => {
                let values = if args.len() == 1 {
                    vec![args[0], 0.0]
                } else if args.len() >= 2 {
                    vec![args[0], args[1]]
                } else {
                    continue;
                };
                out.push(SvgStaticTransform {
                    kind: SvgTransformKind::Translate,
                    values,
                });
            }
            "scale" => {
                let values = if args.len() == 1 {
                    vec![args[0], args[0]]
                } else if args.len() >= 2 {
                    vec![args[0], args[1]]
                } else {
                    continue;
                };
                out.push(SvgStaticTransform {
                    kind: SvgTransformKind::Scale,
                    values,
                });
            }
            "rotate" => {
                let values = if args.len() == 1 {
                    vec![args[0], 0.0, 0.0]
                } else if args.len() >= 3 {
                    vec![args[0], args[1], args[2]]
                } else {
                    continue;
                };
                out.push(SvgStaticTransform {
                    kind: SvgTransformKind::Rotate,
                    values,
                });
            }
            "matrix" => {
                if args.len() != 6 {
                    logs.warn(
                        "parse.transform",
                        "skipping matrix() with wrong arity",
                        &[
                            ("got", (args.len() as u64).into()),
                            ("expected", 6u64.into()),
                        ],
                    );
                    continue;
                }
                out.push(SvgStaticTransform {
                    kind: SvgTransformKind::Matrix,
                    values: args,
                });
            }
            other => {
                logs.warn(
                    "parse.transform",
                    "skipping unsupported transform function",
                    &[("fn", other.into())],
                );
            }
        }
    }
    out
}

fn tokenize_numbers(raw: &str) -> Vec<f64> {
    NUM_RE
        .find_iter(raw)
        .filter_map(|m| m.as_str().parse::<f64>().ok())
        .collect()
}

/// Decomposes `matrix(a b c d e f)` into
/// `translate(e, f) · rotate(θ) · scale(sx, sy)`.
///
/// Pure TRS matrices reconstruct exactly. Sheared matrices recover
/// `sx`, `rot`, `tx`, `ty` correctly and derive `sy` from the
/// determinant so area and orientation are preserved. The shear
/// component is silently dropped — Lottie cannot represent it.
fn decompose_matrix(m: &[f64]) -> Vec<SvgStaticTransform> {
    let (a, b, c, d, e, f) = (m[0], m[1], m[2], m[3], m[4], m[5]);
    let sx = (a * a + b * b).sqrt();
    let sy = if sx.abs() < 1e-9 { 0.0 } else { (a * d - b * c) / sx };
    let rot_deg = b.atan2(a).to_degrees();
    vec![
        SvgStaticTransform {
            kind: SvgTransformKind::Translate,
            values: vec![e, f],
        },
        SvgStaticTransform {
            kind: SvgTransformKind::Rotate,
            values: vec![rot_deg, 0.0, 0.0],
        },
        SvgStaticTransform {
            kind: SvgTransformKind::Scale,
            values: vec![sx, sy],
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn parse_str(s: &str) -> Vec<SvgStaticTransform> {
        let mut logs = LogCollector::new(LogLevel::Warn);
        parse(Some(s), &mut logs)
    }

    #[test]
    fn empty_input_is_empty() {
        let mut logs = LogCollector::new(LogLevel::Warn);
        assert!(parse(None, &mut logs).is_empty());
        assert!(parse(Some(""), &mut logs).is_empty());
        assert!(parse(Some("   "), &mut logs).is_empty());
    }

    #[test]
    fn translate_one_arg_defaults_y_to_zero() {
        let out = parse_str("translate(10)");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, SvgTransformKind::Translate);
        assert_eq!(out[0].values, vec![10.0, 0.0]);
    }

    #[test]
    fn translate_two_args() {
        let out = parse_str("translate(10 20)");
        assert_eq!(out[0].values, vec![10.0, 20.0]);
    }

    #[test]
    fn scale_one_arg_duplicates() {
        let out = parse_str("scale(2)");
        assert_eq!(out[0].kind, SvgTransformKind::Scale);
        assert_eq!(out[0].values, vec![2.0, 2.0]);
    }

    #[test]
    fn rotate_one_arg_defaults_pivot() {
        let out = parse_str("rotate(45)");
        assert_eq!(out[0].kind, SvgTransformKind::Rotate);
        assert_eq!(out[0].values, vec![45.0, 0.0, 0.0]);
    }

    #[test]
    fn rotate_three_args_with_pivot() {
        let out = parse_str("rotate(45 10 20)");
        assert_eq!(out[0].values, vec![45.0, 10.0, 20.0]);
    }

    #[test]
    fn compact_negative_sign_acts_as_delimiter() {
        // `1.01-2-3` → [1.01, -2, -3]
        let out = parse_str("translate(1.01-2)");
        assert_eq!(out[0].values, vec![1.01, -2.0]);
    }

    #[test]
    fn multiple_functions_preserve_order() {
        let out = parse_str("translate(10 20)scale(.5)rotate(45)");
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].kind, SvgTransformKind::Translate);
        assert_eq!(out[1].kind, SvgTransformKind::Scale);
        assert_eq!(out[2].kind, SvgTransformKind::Rotate);
    }

    #[test]
    fn matrix_kept_as_matrix_kind() {
        let out = parse_str("matrix(1 0 0 1 0 0)");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, SvgTransformKind::Matrix);
        assert_eq!(out[0].values, vec![1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
    }

    #[test]
    fn matrix_with_rotation_and_shear_keeps_all_six_values() {
        let out = parse_str("matrix(.710141 -.41 0.71 0.409919 -555 292)");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, SvgTransformKind::Matrix);
        assert_eq!(out[0].values.len(), 6);
        assert!((out[0].values[0] - 0.710141).abs() < 1e-9);
        assert!((out[0].values[1] - -0.41).abs() < 1e-9);
        assert!((out[0].values[2] - 0.71).abs() < 1e-9);
        assert!((out[0].values[3] - 0.409919).abs() < 1e-9);
    }

    #[test]
    fn matrix_wrong_arity_is_skipped() {
        let out = parse_str("matrix(1 0 0 1 0)");
        assert!(out.is_empty());
    }

    #[test]
    fn unsupported_function_is_skipped() {
        let out = parse_str("skewX(10)translate(1 2)");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, SvgTransformKind::Translate);
    }
}
