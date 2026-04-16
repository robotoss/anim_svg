//! Smoke test: every domain type serializes to JSON without panicking
//! and preserves the fields the envelope needs to expose to Dart.

use anim_svg_core::domain::{
    BezierHandle, LottieDoc, LottieLayer, LottieLayerCommon, LottieScalarKeyframe,
    LottieScalarProp, LottieShapeFill, LottieShapeGeometry, LottieShapeItem, LottieShapeKind,
    LottieShapeLayer, LottieTransform, LottieVectorKeyframe, LottieVectorProp, SvgAnimationAdditive,
    SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode, SvgDefs, SvgDocument, SvgGradient,
    SvgGradientKind, SvgGroup, SvgKeyframes, SvgMotionPath, SvgMotionRotate, SvgNode,
    SvgNodeCommon, SvgShape, SvgShapeKind, SvgStaticTransform, SvgStop, SvgTransformKind,
    SvgViewBox,
};

#[test]
fn svg_document_round_trips_minimal() {
    let shape = SvgShape {
        common: SvgNodeCommon {
            id: Some("s1".to_string()),
            static_transforms: vec![SvgStaticTransform {
                kind: SvgTransformKind::Translate,
                values: vec![10.0, 20.0],
            }],
            animations: vec![SvgAnimationNode::Animate {
                attribute_name: "opacity".to_string(),
                common: SvgAnimationCommon {
                    dur_seconds: 1.0,
                    repeat_indefinite: true,
                    additive: SvgAnimationAdditive::Replace,
                    keyframes: SvgKeyframes {
                        key_times: vec![0.0, 1.0],
                        values: vec!["0".to_string(), "1".to_string()],
                        calc_mode: SvgAnimationCalcMode::Linear,
                        key_splines: vec![],
                    },
                    delay_seconds: 0.0,
                    direction: Default::default(),
                    fill_mode: Default::default(),
                },
            }],
            motion_path: Some(SvgMotionPath {
                path_data: "M0 0 L10 10".to_string(),
                rotate: SvgMotionRotate::AUTO,
            }),
            ..Default::default()
        },
        kind: SvgShapeKind::Path,
        d: Some("M0 0 L10 10 Z".to_string()),
        fill: "#ff0000".to_string(),
        ..Default::default()
    };

    let group = SvgGroup {
        common: SvgNodeCommon::default(),
        children: vec![SvgNode::Shape(shape)],
        display_none: false,
    };

    let doc = SvgDocument {
        width: 100.0,
        height: 100.0,
        view_box: SvgViewBox {
            x: 0.0,
            y: 0.0,
            w: 100.0,
            h: 100.0,
        },
        defs: SvgDefs::default(),
        root: group,
    };

    let json = serde_json::to_string(&doc).expect("SvgDocument serializes");
    let v: serde_json::Value = serde_json::from_str(&json).expect("is valid JSON");
    assert_eq!(v["width"], 100.0);
    assert_eq!(v["root"]["children"][0]["type"], "shape");
    assert_eq!(v["root"]["children"][0]["kind"], "path");
    assert_eq!(
        v["root"]["children"][0]["animations"][0]["attributeName"],
        "opacity"
    );
}

#[test]
fn lottie_doc_serializes_with_layer_variants() {
    let shape_layer = LottieShapeLayer {
        common: LottieLayerCommon {
            index: 1,
            name: "s1".to_string(),
            transform: LottieTransform::default(),
            in_point: 0.0,
            out_point: 60.0,
            effects: vec![],
            parent: None,
            td: None,
            tt: None,
        },
        shapes: vec![
            LottieShapeItem::Geometry(LottieShapeGeometry {
                kind: LottieShapeKind::Path,
                vertices: vec![[0.0, 0.0], [10.0, 10.0]],
                in_tangents: vec![[0.0, 0.0], [0.0, 0.0]],
                out_tangents: vec![[0.0, 0.0], [0.0, 0.0]],
                closed: true,
                ..Default::default()
            }),
            LottieShapeItem::Fill(LottieShapeFill {
                color: [1.0, 0.0, 0.0, 1.0],
                opacity: 100.0,
            }),
        ],
    };

    let doc = LottieDoc {
        version: LottieDoc::DEFAULT_VERSION.to_string(),
        frame_rate: 60.0,
        in_point: 0.0,
        out_point: 60.0,
        width: 100.0,
        height: 100.0,
        assets: vec![],
        layers: vec![LottieLayer::Shape(shape_layer)],
    };

    let json = serde_json::to_string(&doc).expect("LottieDoc serializes");
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["version"], "5.7.0");
    assert_eq!(v["layers"][0]["type"], "shape");
    assert_eq!(v["layers"][0]["shapes"][0]["type"], "geometry");
    assert_eq!(v["layers"][0]["shapes"][1]["type"], "fill");
}

#[test]
fn scalar_and_vector_props_tag_variants() {
    let s = LottieScalarProp::Animated {
        keyframes: vec![LottieScalarKeyframe {
            time: 0.0,
            start: 100.0,
            hold: false,
            bezier_in: Some(BezierHandle { x: 0.5, y: 0.5 }),
            bezier_out: None,
        }],
    };
    let vt = LottieVectorProp::Animated {
        keyframes: vec![LottieVectorKeyframe {
            time: 0.0,
            start: vec![1.0, 2.0],
            hold: false,
            bezier_in: None,
            bezier_out: None,
        }],
    };

    let js = serde_json::to_value(&s).unwrap();
    let jv = serde_json::to_value(&vt).unwrap();
    assert_eq!(js["type"], "animated");
    assert_eq!(jv["type"], "animated");
}

// Ensure unused gradient imports still link — otherwise rustc emits a
// warning-as-info and we want to know this file is wired correctly.
#[allow(dead_code)]
fn _uses_gradient(_g: SvgGradient, _k: SvgGradientKind, _s: SvgStop) {}
