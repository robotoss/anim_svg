//! Port of `lib/src/domain/entities/svg_transform.dart`.

use serde::Serialize;

use super::svg_anim::SvgTransformKind;

/// A single static SVG transform parsed from `transform="..."`.
///
/// Layout of `values` matches the Dart side:
///   - `translate`: `[x, y]`
///   - `scale`:     `[sx, sy]`
///   - `rotate`:    `[deg, cx, cy]`
///   - `skewX/Y`:   `[deg]`
///   - `matrix`:    `[a, b, c, d, e, f]` (SVG order)
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SvgStaticTransform {
    pub kind: SvgTransformKind,
    pub values: Vec<f64>,
}
