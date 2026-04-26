//! Port of `lib/src/data/serializers/lottie_serializer.dart`.
//!
//! Emits the wire-format Lottie 5.7 JSON that thorvg / lottie-web consume.
//! The domain types carry descriptive names (`position`, `frame_rate`); the
//! schema uses short two-letter keys (`p`, `fr`). This module is the
//! translation layer — it is hand-written because key order matters for
//! human-diffable output and several fields are conditional.

use serde_json::{json, Map, Value};

use crate::domain::{
    BezierHandle, LottieAsset, LottieDoc, LottieEffect, LottieGradientKind, LottieGradientStops,
    LottieImageLayer, LottieLayer, LottieNullLayer, LottieScalarKeyframe, LottieScalarProp,
    LottieShapeGeometry, LottieShapeGradientFill, LottieShapeItem, LottieShapeKind,
    LottieShapeLayer, LottieShapePathKeyframe, LottieShapeStroke, LottieShapeTrimPath,
    LottieTransform, LottieVectorKeyframe, LottieVectorProp,
};

/// Entry point: produce the full Lottie document as a `serde_json::Value`.
pub fn serialize(doc: &LottieDoc) -> Value {
    json!({
        "v": doc.version,
        "fr": doc.frame_rate,
        "ip": doc.in_point,
        "op": doc.out_point,
        "w": doc.width as i64,
        "h": doc.height as i64,
        "nm": "anim_svg",
        "ddd": 0,
        "assets": doc.assets.iter().map(asset_map).collect::<Vec<_>>(),
        "layers": doc.layers.iter().map(layer_map).collect::<Vec<_>>(),
    })
}

fn asset_map(a: &LottieAsset) -> Value {
    json!({
        "id": a.id,
        "w": a.width,
        "h": a.height,
        "u": "",
        "p": a.data_uri,
        "e": 1,
    })
}

fn layer_map(l: &LottieLayer) -> Value {
    match l {
        LottieLayer::Image(layer) => image_layer_map(layer),
        LottieLayer::Shape(layer) => shape_layer_map(layer),
        LottieLayer::Null(layer) => null_layer_map(layer),
    }
}

fn image_layer_map(l: &LottieImageLayer) -> Value {
    let c = &l.common;
    let mut m = Map::new();
    m.insert("ddd".into(), json!(0));
    m.insert("ind".into(), json!(c.index));
    m.insert("ty".into(), json!(2));
    m.insert("nm".into(), json!(c.name));
    m.insert("refId".into(), json!(l.ref_id));
    m.insert("sr".into(), json!(1));
    m.insert("ks".into(), transform_map(&c.transform));
    m.insert("ao".into(), json!(0));
    m.insert("ip".into(), json!(c.in_point));
    m.insert("op".into(), json!(c.out_point));
    m.insert("st".into(), json!(0));
    m.insert("bm".into(), json!(0));
    if let Some(w) = l.width {
        m.insert("w".into(), json!(w));
    }
    if let Some(h) = l.height {
        m.insert("h".into(), json!(h));
    }
    if let Some(p) = c.parent {
        m.insert("parent".into(), json!(p));
    }
    if let Some(td) = c.td {
        m.insert("td".into(), json!(td));
    }
    if let Some(tt) = c.tt {
        m.insert("tt".into(), json!(tt));
    }
    if !c.effects.is_empty() {
        m.insert(
            "ef".into(),
            Value::Array(c.effects.iter().map(effect_map).collect()),
        );
    }
    Value::Object(m)
}

fn shape_layer_map(l: &LottieShapeLayer) -> Value {
    let c = &l.common;
    let mut m = Map::new();
    m.insert("ddd".into(), json!(0));
    m.insert("ind".into(), json!(c.index));
    m.insert("ty".into(), json!(4));
    m.insert("nm".into(), json!(c.name));
    m.insert("sr".into(), json!(1));
    m.insert("ks".into(), transform_map(&c.transform));
    m.insert("ao".into(), json!(0));
    m.insert("shapes".into(), json!([shape_group(&l.shapes)]));
    m.insert("ip".into(), json!(c.in_point));
    m.insert("op".into(), json!(c.out_point));
    m.insert("st".into(), json!(0));
    m.insert("bm".into(), json!(0));
    if let Some(p) = c.parent {
        m.insert("parent".into(), json!(p));
    }
    if let Some(td) = c.td {
        m.insert("td".into(), json!(td));
    }
    if let Some(tt) = c.tt {
        m.insert("tt".into(), json!(tt));
    }
    if !c.effects.is_empty() {
        m.insert(
            "ef".into(),
            Value::Array(c.effects.iter().map(effect_map).collect()),
        );
    }
    Value::Object(m)
}

fn null_layer_map(l: &LottieNullLayer) -> Value {
    let c = &l.common;
    let mut m = Map::new();
    m.insert("ddd".into(), json!(0));
    m.insert("ind".into(), json!(c.index));
    m.insert("ty".into(), json!(3));
    m.insert("nm".into(), json!(c.name));
    m.insert("sr".into(), json!(1));
    m.insert("ks".into(), transform_map(&c.transform));
    m.insert("ao".into(), json!(0));
    m.insert("ip".into(), json!(c.in_point));
    m.insert("op".into(), json!(c.out_point));
    m.insert("st".into(), json!(0));
    m.insert("bm".into(), json!(0));
    if let Some(p) = c.parent {
        m.insert("parent".into(), json!(p));
    }
    if let Some(td) = c.td {
        m.insert("td".into(), json!(td));
    }
    if let Some(tt) = c.tt {
        m.insert("tt".into(), json!(tt));
    }
    Value::Object(m)
}

fn effect_map(e: &LottieEffect) -> Value {
    match e {
        LottieEffect::Blur { blurriness } => json!({
            "ty": 29,
            "nm": "Gaussian Blur",
            "np": 3,
            "mn": "ADBE Gaussian Blur 2",
            "ef": [
                {
                    "ty": 0,
                    "nm": "Blurriness",
                    "mn": "ADBE Gaussian Blur 2-0001",
                    "v": scalar_prop(blurriness),
                },
                {
                    "ty": 7,
                    "nm": "Blur Dimensions",
                    "mn": "ADBE Gaussian Blur 2-0002",
                    "v": {"a": 0, "k": 1},
                },
                {
                    "ty": 7,
                    "nm": "Repeat Edge Pixels",
                    "mn": "ADBE Gaussian Blur 2-0003",
                    "v": {"a": 0, "k": 0},
                },
            ],
        }),
        LottieEffect::Brightness { brightness } => json!({
            "ty": 22,
            "nm": "Brightness & Contrast",
            "np": 3,
            "mn": "ADBE Brightness & Contrast 2",
            "ef": [
                {
                    "ty": 0,
                    "nm": "Brightness",
                    "mn": "ADBE Brightness & Contrast 2-0001",
                    "v": scalar_prop(brightness),
                },
                {
                    "ty": 0,
                    "nm": "Contrast",
                    "mn": "ADBE Brightness & Contrast 2-0002",
                    "v": {"a": 0, "k": 0},
                },
                {
                    "ty": 7,
                    "nm": "Use Legacy",
                    "mn": "ADBE Brightness & Contrast 2-0003",
                    "v": {"a": 0, "k": 0},
                },
            ],
        }),
        LottieEffect::HueSaturation { master_saturation } => json!({
            "ty": 19,
            "nm": "Hue/Saturation",
            "np": 9,
            "mn": "ADBE HUE SATURATION",
            "ef": [
                {
                    "ty": 7,
                    "nm": "Channel Control",
                    "mn": "ADBE HUE SATURATION-0001",
                    "v": {"a": 0, "k": 0},
                },
                {
                    "ty": 0,
                    "nm": "Master Hue",
                    "mn": "ADBE HUE SATURATION-0002",
                    "v": {"a": 0, "k": 0},
                },
                {
                    "ty": 0,
                    "nm": "Master Saturation",
                    "mn": "ADBE HUE SATURATION-0003",
                    "v": scalar_prop(master_saturation),
                },
                {
                    "ty": 0,
                    "nm": "Master Lightness",
                    "mn": "ADBE HUE SATURATION-0004",
                    "v": {"a": 0, "k": 0},
                },
                {
                    "ty": 7,
                    "nm": "Colorize",
                    "mn": "ADBE HUE SATURATION-0005",
                    "v": {"a": 0, "k": 0},
                },
            ],
        }),
    }
}

fn shape_group(items: &[LottieShapeItem]) -> Value {
    let mut it: Vec<Value> = items.iter().map(shape_item).collect();
    it.push(group_transform());
    json!({
        "ty": "gr",
        "it": it,
    })
}

fn shape_item(it: &LottieShapeItem) -> Value {
    match it {
        LottieShapeItem::Geometry(g) => geometry_item(g),
        LottieShapeItem::Fill(f) => json!({
            "ty": "fl",
            "c": {"a": 0, "k": f.color.to_vec()},
            "o": {"a": 0, "k": f.opacity},
            "r": 1,
            "bm": 0,
        }),
        LottieShapeItem::GradientFill(g) => gradient_fill(g),
        LottieShapeItem::Stroke(s) => stroke_item(s),
        LottieShapeItem::TrimPath(t) => trim_path_item(t),
    }
}

fn geometry_item(g: &LottieShapeGeometry) -> Value {
    match g.kind {
        LottieShapeKind::Path => match &g.path_keyframes {
            None => json!({
                "ty": "sh",
                "ks": {
                    "a": 0,
                    "k": {
                        "i": vec2_array(&g.in_tangents),
                        "o": vec2_array(&g.out_tangents),
                        "v": vec2_array(&g.vertices),
                        "c": g.closed,
                    },
                },
            }),
            Some(kfs) => json!({
                "ty": "sh",
                "ks": {
                    "a": 1,
                    "k": kfs.iter().map(path_keyframe).collect::<Vec<_>>(),
                },
            }),
        },
        LottieShapeKind::Rect => json!({
            "ty": "rc",
            "p": {"a": 0, "k": g.rect_position.to_vec()},
            "s": {"a": 0, "k": g.rect_size.to_vec()},
            "r": {"a": 0, "k": g.rect_roundness},
        }),
        LottieShapeKind::Ellipse => json!({
            "ty": "el",
            "p": {"a": 0, "k": g.ellipse_position.to_vec()},
            "s": {"a": 0, "k": g.ellipse_size.to_vec()},
        }),
    }
}

fn path_keyframe(k: &LottieShapePathKeyframe) -> Value {
    let mut m = Map::new();
    m.insert("t".into(), json!(k.time));
    m.insert(
        "s".into(),
        json!([{
            "i": vec2_array(&k.in_tangents),
            "o": vec2_array(&k.out_tangents),
            "v": vec2_array(&k.vertices),
            "c": k.closed,
        }]),
    );
    if k.hold {
        m.insert("h".into(), json!(1));
    }
    if let Some(bo) = k.bezier_out {
        m.insert("o".into(), handle_map(&bo));
    }
    if let Some(bi) = k.bezier_in {
        m.insert("i".into(), handle_map(&bi));
    }
    Value::Object(m)
}

fn stroke_item(s: &LottieShapeStroke) -> Value {
    json!({
        "ty": "st",
        "c": {"a": 0, "k": s.color.to_vec()},
        "o": {"a": 0, "k": s.opacity},
        "w": {"a": 0, "k": s.width},
        "lc": s.line_cap,
        "lj": s.line_join,
        "ml": s.miter_limit,
        "bm": 0,
    })
}

fn trim_path_item(t: &LottieShapeTrimPath) -> Value {
    json!({
        "ty": "tm",
        "s": scalar_prop(&t.start),
        "e": scalar_prop(&t.end),
        "o": scalar_prop(&t.offset),
        "m": 1,
    })
}

fn gradient_fill(g: &LottieShapeGradientFill) -> Value {
    let gk = match &g.stops {
        LottieGradientStops::Static { values } => json!({"a": 0, "k": values}),
        LottieGradientStops::Animated { keyframes } => {
            let kfs: Vec<Value> = keyframes
                .iter()
                .map(|kf| {
                    let mut m = Map::new();
                    m.insert("t".into(), json!(kf.time));
                    m.insert("s".into(), json!(kf.values));
                    if kf.hold {
                        m.insert("h".into(), json!(1));
                    }
                    Value::Object(m)
                })
                .collect();
            json!({"a": 1, "k": kfs})
        }
    };
    json!({
        "ty": "gf",
        "o": {"a": 0, "k": g.opacity},
        "r": 1,
        "bm": 0,
        "t": if g.kind == LottieGradientKind::Radial { 2 } else { 1 },
        "g": {"p": g.color_stop_count, "k": gk},
        "s": {"a": 0, "k": g.start_point.to_vec()},
        "e": {"a": 0, "k": g.end_point.to_vec()},
    })
}

/// Every Lottie shape group requires its own `tr` transform (identity when
/// we don't have anything special to apply — the layer-level transform in
/// `ks` does the work).
fn group_transform() -> Value {
    json!({
        "ty": "tr",
        "a": {"a": 0, "k": [0, 0]},
        "p": {"a": 0, "k": [0, 0]},
        "s": {"a": 0, "k": [100, 100]},
        "r": {"a": 0, "k": 0},
        "o": {"a": 0, "k": 100},
        "sk": {"a": 0, "k": 0},
        "sa": {"a": 0, "k": 0},
    })
}

fn transform_map(t: &LottieTransform) -> Value {
    json!({
        "a": vector_prop(&t.anchor),
        "p": vector_prop(&t.position),
        "s": vector_prop(&t.scale),
        "r": scalar_prop(&t.rotation),
        "o": scalar_prop(&t.opacity),
        "sk": scalar_prop(&t.skew),
        "sa": scalar_prop(&t.skew_axis),
    })
}

fn vector_prop(p: &LottieVectorProp) -> Value {
    match p {
        LottieVectorProp::Static { value } => json!({"a": 0, "k": value}),
        LottieVectorProp::Animated { keyframes } => json!({
            "a": 1,
            "k": keyframes.iter().map(vector_keyframe).collect::<Vec<_>>(),
        }),
    }
}

fn scalar_prop(p: &LottieScalarProp) -> Value {
    match p {
        LottieScalarProp::Static { value } => json!({"a": 0, "k": value}),
        LottieScalarProp::Animated { keyframes } => json!({
            "a": 1,
            "k": keyframes.iter().map(scalar_keyframe).collect::<Vec<_>>(),
        }),
    }
}

fn vector_keyframe(k: &LottieVectorKeyframe) -> Value {
    let mut m = Map::new();
    m.insert("t".into(), json!(k.time));
    m.insert("s".into(), json!(k.start));
    if k.hold {
        m.insert("h".into(), json!(1));
    }
    if let Some(bi) = k.bezier_in {
        m.insert("i".into(), handle_map(&bi));
    }
    if let Some(bo) = k.bezier_out {
        m.insert("o".into(), handle_map(&bo));
    }
    Value::Object(m)
}

fn scalar_keyframe(k: &LottieScalarKeyframe) -> Value {
    let mut m = Map::new();
    m.insert("t".into(), json!(k.time));
    m.insert("s".into(), json!([k.start]));
    if k.hold {
        m.insert("h".into(), json!(1));
    }
    if let Some(bi) = k.bezier_in {
        m.insert("i".into(), handle_map(&bi));
    }
    if let Some(bo) = k.bezier_out {
        m.insert("o".into(), handle_map(&bo));
    }
    Value::Object(m)
}

fn handle_map(h: &BezierHandle) -> Value {
    json!({"x": [h.x], "y": [h.y]})
}

/// Convert a `Vec<[f64;2]>` into a JSON-ready `Vec<Vec<f64>>` so we get
/// `[[x,y], [x,y]]` rather than a flat tuple per pair.
fn vec2_array(v: &[[f64; 2]]) -> Vec<Vec<f64>> {
    v.iter().map(|p| p.to_vec()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        LottieAsset, LottieEffect, LottieGradientKeyframe, LottieGradientKind,
        LottieGradientStops, LottieImageLayer, LottieLayer, LottieLayerCommon, LottieNullLayer,
        LottieScalarKeyframe, LottieScalarProp, LottieShapeFill, LottieShapeGeometry,
        LottieShapeGradientFill, LottieShapeItem, LottieShapeKind, LottieShapeLayer,
        LottieShapeTrimPath, LottieTransform, LottieVectorKeyframe, LottieVectorProp,
    };

    fn empty_doc() -> LottieDoc {
        LottieDoc {
            version: "5.7.0".to_string(),
            frame_rate: 60.0,
            in_point: 0.0,
            out_point: 60.0,
            width: 200.0,
            height: 100.0,
            assets: Vec::new(),
            layers: Vec::new(),
        }
    }

    #[test]
    fn minimal_empty_doc_has_correct_top_level_keys() {
        let v = serialize(&empty_doc());
        assert_eq!(v["v"], "5.7.0");
        assert_eq!(v["fr"], 60.0);
        assert_eq!(v["ip"], 0.0);
        assert_eq!(v["op"], 60.0);
        // `w` and `h` are ints in the wire format even if domain uses f64.
        assert_eq!(v["w"], 200);
        assert_eq!(v["h"], 100);
        assert_eq!(v["nm"], "anim_svg");
        assert_eq!(v["ddd"], 0);
        assert!(v["assets"].is_array() && v["assets"].as_array().unwrap().is_empty());
        assert!(v["layers"].is_array() && v["layers"].as_array().unwrap().is_empty());
    }

    #[test]
    fn shape_layer_with_geometry_and_fill() {
        let mut doc = empty_doc();
        let shapes = vec![
            LottieShapeItem::Geometry(LottieShapeGeometry {
                kind: LottieShapeKind::Rect,
                rect_position: [10.0, 20.0],
                rect_size: [30.0, 40.0],
                rect_roundness: 5.0,
                ..Default::default()
            }),
            LottieShapeItem::Fill(LottieShapeFill {
                color: [1.0, 0.0, 0.0, 1.0],
                opacity: 100.0,
            }),
        ];
        doc.layers.push(LottieLayer::Shape(LottieShapeLayer {
            common: LottieLayerCommon {
                index: 1,
                name: "rect".to_string(),
                transform: LottieTransform::default(),
                in_point: 0.0,
                out_point: 60.0,
                effects: Vec::new(),
                parent: None,
                td: None,
                tt: None,
            },
            shapes,
        }));

        let v = serialize(&doc);
        let layer = &v["layers"][0];
        assert_eq!(layer["ty"], 4);
        assert_eq!(layer["nm"], "rect");
        assert_eq!(layer["ind"], 1);
        let group = &layer["shapes"][0];
        assert_eq!(group["ty"], "gr");
        let items = group["it"].as_array().unwrap();
        // rect + fill + group-transform
        assert_eq!(items.len(), 3);
        assert_eq!(items[0]["ty"], "rc");
        assert_eq!(items[0]["p"]["k"], json!([10.0, 20.0]));
        assert_eq!(items[0]["s"]["k"], json!([30.0, 40.0]));
        assert_eq!(items[0]["r"]["k"], 5.0);
        assert_eq!(items[1]["ty"], "fl");
        assert_eq!(items[1]["c"]["k"], json!([1.0, 0.0, 0.0, 1.0]));
        assert_eq!(items[1]["o"]["k"], 100.0);
        assert_eq!(items[1]["r"], 1);
        assert_eq!(items[2]["ty"], "tr");
        assert_eq!(items[2]["s"]["k"], json!([100, 100]));
    }

    #[test]
    fn animated_position_keyframes() {
        let anim = LottieVectorProp::Animated {
            keyframes: vec![
                LottieVectorKeyframe {
                    time: 0.0,
                    start: vec![0.0, 0.0],
                    hold: false,
                    bezier_in: Some(BezierHandle { x: 0.5, y: 0.5 }),
                    bezier_out: Some(BezierHandle { x: 0.1, y: 0.2 }),
                },
                LottieVectorKeyframe {
                    time: 30.0,
                    start: vec![100.0, 0.0],
                    hold: true,
                    bezier_in: None,
                    bezier_out: None,
                },
            ],
        };
        let v = vector_prop(&anim);
        assert_eq!(v["a"], 1);
        let kfs = v["k"].as_array().unwrap();
        assert_eq!(kfs[0]["t"], 0.0);
        assert_eq!(kfs[0]["s"], json!([0.0, 0.0]));
        assert_eq!(kfs[0]["i"], json!({"x": [0.5], "y": [0.5]}));
        assert_eq!(kfs[0]["o"], json!({"x": [0.1], "y": [0.2]}));
        assert!(kfs[0].get("h").is_none());
        assert_eq!(kfs[1]["t"], 30.0);
        assert_eq!(kfs[1]["h"], 1);
    }

    #[test]
    fn static_scalar_vs_animated_scalar() {
        let s = scalar_prop(&LottieScalarProp::Static { value: 42.0 });
        assert_eq!(s, json!({"a": 0, "k": 42.0}));

        let a = scalar_prop(&LottieScalarProp::Animated {
            keyframes: vec![LottieScalarKeyframe {
                time: 0.0,
                start: 1.0,
                hold: false,
                bezier_in: None,
                bezier_out: None,
            }],
        });
        assert_eq!(a["a"], 1);
        // Scalar keyframe `s` is wrapped in an array — Lottie quirk.
        assert_eq!(a["k"][0]["s"], json!([1.0]));
    }

    #[test]
    fn trim_path_serializes_to_tm() {
        let t = LottieShapeItem::TrimPath(LottieShapeTrimPath {
            start: LottieScalarProp::Static { value: 0.0 },
            end: LottieScalarProp::Static { value: 100.0 },
            offset: LottieScalarProp::Static { value: 0.0 },
        });
        let v = shape_item(&t);
        assert_eq!(v["ty"], "tm");
        assert_eq!(v["s"], json!({"a": 0, "k": 0.0}));
        assert_eq!(v["e"], json!({"a": 0, "k": 100.0}));
        assert_eq!(v["o"], json!({"a": 0, "k": 0.0}));
        assert_eq!(v["m"], 1);
    }

    #[test]
    fn gradient_fill_static_stops() {
        let g = LottieShapeItem::GradientFill(LottieShapeGradientFill {
            kind: LottieGradientKind::Linear,
            color_stop_count: 2,
            start_point: [0.0, 0.0],
            end_point: [100.0, 0.0],
            stops: LottieGradientStops::Static {
                values: vec![0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0],
            },
            opacity: 100.0,
        });
        let v = shape_item(&g);
        assert_eq!(v["ty"], "gf");
        assert_eq!(v["t"], 1);
        assert_eq!(v["g"]["p"], 2);
        assert_eq!(v["g"]["k"]["a"], 0);
        assert_eq!(v["r"], 1);
        assert_eq!(v["s"]["k"], json!([0.0, 0.0]));
        assert_eq!(v["e"]["k"], json!([100.0, 0.0]));
    }

    #[test]
    fn gradient_fill_animated_stops_and_radial_kind() {
        let g = LottieShapeItem::GradientFill(LottieShapeGradientFill {
            kind: LottieGradientKind::Radial,
            color_stop_count: 2,
            start_point: [0.0, 0.0],
            end_point: [50.0, 50.0],
            stops: LottieGradientStops::Animated {
                keyframes: vec![
                    LottieGradientKeyframe {
                        time: 0.0,
                        values: vec![0.0, 1.0, 0.0, 0.0],
                        hold: false,
                    },
                    LottieGradientKeyframe {
                        time: 30.0,
                        values: vec![0.0, 0.0, 1.0, 0.0],
                        hold: true,
                    },
                ],
            },
            opacity: 100.0,
        });
        let v = shape_item(&g);
        assert_eq!(v["t"], 2); // radial
        assert_eq!(v["g"]["k"]["a"], 1);
        let kfs = v["g"]["k"]["k"].as_array().unwrap();
        assert_eq!(kfs[0]["t"], 0.0);
        assert!(kfs[0].get("h").is_none());
        assert_eq!(kfs[1]["h"], 1);
    }

    #[test]
    fn image_layer_references_asset() {
        let mut doc = empty_doc();
        doc.assets.push(LottieAsset {
            id: "image_0".to_string(),
            width: 64.0,
            height: 64.0,
            data_uri: "data:image/png;base64,AAAA".to_string(),
        });
        doc.layers.push(LottieLayer::Image(LottieImageLayer {
            common: LottieLayerCommon {
                index: 1,
                name: "img".to_string(),
                transform: LottieTransform::default(),
                in_point: 0.0,
                out_point: 60.0,
                effects: Vec::new(),
                parent: None,
                td: None,
                tt: None,
            },
            ref_id: "image_0".to_string(),
            width: Some(64.0),
            height: Some(64.0),
        }));
        let v = serialize(&doc);
        assert_eq!(v["assets"][0]["id"], "image_0");
        assert_eq!(v["assets"][0]["e"], 1);
        assert_eq!(v["assets"][0]["u"], "");
        assert_eq!(v["assets"][0]["p"], "data:image/png;base64,AAAA");
        let layer = &v["layers"][0];
        assert_eq!(layer["ty"], 2);
        assert_eq!(layer["refId"], "image_0");
        assert_eq!(layer["w"], 64.0);
        assert_eq!(layer["h"], 64.0);
    }

    #[test]
    fn null_layer_serializes_to_ty_3() {
        let mut doc = empty_doc();
        doc.layers.push(LottieLayer::Null(LottieNullLayer {
            common: LottieLayerCommon {
                index: 99,
                name: "null".to_string(),
                transform: LottieTransform::default(),
                in_point: 0.0,
                out_point: 60.0,
                effects: Vec::new(),
                parent: Some(1),
                td: None,
                tt: None,
            },
        }));
        let v = serialize(&doc);
        let layer = &v["layers"][0];
        assert_eq!(layer["ty"], 3);
        assert_eq!(layer["ind"], 99);
        assert_eq!(layer["parent"], 1);
        assert!(layer.get("shapes").is_none());
        assert!(layer.get("refId").is_none());
    }

    #[test]
    fn blur_effect_emits_ty_29_with_nested_ef_array() {
        let e = LottieEffect::Blur {
            blurriness: LottieScalarProp::Static { value: 5.0 },
        };
        let v = effect_map(&e);
        assert_eq!(v["ty"], 29);
        assert_eq!(v["nm"], "Gaussian Blur");
        assert_eq!(v["mn"], "ADBE Gaussian Blur 2");
        let inner = v["ef"].as_array().unwrap();
        assert_eq!(inner.len(), 3);
        assert_eq!(inner[0]["nm"], "Blurriness");
        assert_eq!(inner[0]["v"], json!({"a": 0, "k": 5.0}));
        // Dims=1 means "horizontal and vertical" — preserved from Dart.
        assert_eq!(inner[1]["v"], json!({"a": 0, "k": 1}));
        assert_eq!(inner[2]["v"], json!({"a": 0, "k": 0}));
    }

    #[test]
    fn path_geometry_static_without_keyframes() {
        let g = LottieShapeItem::Geometry(LottieShapeGeometry {
            kind: LottieShapeKind::Path,
            vertices: vec![[0.0, 0.0], [10.0, 10.0]],
            in_tangents: vec![[0.0, 0.0], [0.0, 0.0]],
            out_tangents: vec![[0.0, 0.0], [0.0, 0.0]],
            closed: true,
            path_keyframes: None,
            ..Default::default()
        });
        let v = shape_item(&g);
        assert_eq!(v["ty"], "sh");
        assert_eq!(v["ks"]["a"], 0);
        assert_eq!(v["ks"]["k"]["v"], json!([[0.0, 0.0], [10.0, 10.0]]));
        assert_eq!(v["ks"]["k"]["c"], true);
    }

    #[test]
    fn path_geometry_with_keyframes_emits_animated() {
        let g = LottieShapeItem::Geometry(LottieShapeGeometry {
            kind: LottieShapeKind::Path,
            vertices: vec![[0.0, 0.0]],
            in_tangents: vec![[0.0, 0.0]],
            out_tangents: vec![[0.0, 0.0]],
            closed: true,
            path_keyframes: Some(vec![LottieShapePathKeyframe {
                time: 0.0,
                vertices: vec![[0.0, 0.0]],
                in_tangents: vec![[0.0, 0.0]],
                out_tangents: vec![[0.0, 0.0]],
                closed: true,
                hold: true,
                bezier_in: Some(BezierHandle { x: 0.2, y: 0.3 }),
                bezier_out: Some(BezierHandle { x: 0.4, y: 0.5 }),
            }]),
            ..Default::default()
        });
        let v = shape_item(&g);
        assert_eq!(v["ty"], "sh");
        assert_eq!(v["ks"]["a"], 1);
        let kf = &v["ks"]["k"][0];
        assert_eq!(kf["t"], 0.0);
        assert_eq!(kf["h"], 1);
        // `s` holds a single-element array containing the vertex/tangent record.
        assert_eq!(kf["s"][0]["v"], json!([[0.0, 0.0]]));
        assert_eq!(kf["i"], json!({"x": [0.2], "y": [0.3]}));
        assert_eq!(kf["o"], json!({"x": [0.4], "y": [0.5]}));
    }
}
