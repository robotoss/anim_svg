use std::collections::HashMap;

use serde_json::Value;

use crate::domain::lottie::{LottieDoc, LottieLayer, LottieVectorProp};
use crate::log::LogCollector;

const MAX_PARENT_DEPTH: usize = 16;
const OUT_OF_COMP_MARGIN: f64 = 0.5;

#[derive(Debug, Clone, Copy)]
struct WorldTransform {
    pos: (f64, f64),
    scale: (f64, f64),
}

pub fn validate(doc: &LottieDoc, logs: &mut LogCollector) {
    if doc.layers.is_empty() {
        return;
    }

    let by_index: HashMap<i32, &LottieLayer> = doc
        .layers
        .iter()
        .map(|l| (l.common().index, l))
        .collect();

    let cw = doc.width;
    let ch = doc.height;
    let xmin = -cw * OUT_OF_COMP_MARGIN;
    let xmax = cw * (1.0 + OUT_OF_COMP_MARGIN);
    let ymin = -ch * OUT_OF_COMP_MARGIN;
    let ymax = ch * (1.0 + OUT_OF_COMP_MARGIN);

    for layer in &doc.layers {
        let world = match world_transform_at_zero(layer, &by_index, 0) {
            Some(w) => w,
            None => continue,
        };
        let (x, y) = world.pos;
        if x < xmin || x > xmax || y < ymin || y > ymax {
            let common = layer.common();
            logs.warn(
                "validate.position",
                "layer position is outside composition bounds at t=0",
                &[
                    ("layer_index", Value::from(common.index)),
                    ("layer_name", Value::from(common.name.clone())),
                    ("layer_type", Value::from(layer_type_str(layer))),
                    ("position_x", Value::from(round1(x))),
                    ("position_y", Value::from(round1(y))),
                    ("comp_width", Value::from(cw)),
                    ("comp_height", Value::from(ch)),
                    ("parent_index", parent_field(common.parent)),
                ],
            );
        }
    }
}

fn world_transform_at_zero(
    layer: &LottieLayer,
    by_index: &HashMap<i32, &LottieLayer>,
    depth: usize,
) -> Option<WorldTransform> {
    if depth >= MAX_PARENT_DEPTH {
        return None;
    }
    let common = layer.common();
    let own_pos = first_xy(&common.transform.position).unwrap_or((0.0, 0.0));
    let own_scale_pct = first_xy(&common.transform.scale).unwrap_or((100.0, 100.0));
    let own_scale = (own_scale_pct.0 / 100.0, own_scale_pct.1 / 100.0);

    let parent = match common.parent {
        Some(p) => p,
        None => {
            return Some(WorldTransform {
                pos: own_pos,
                scale: own_scale,
            });
        }
    };

    let parent_layer = by_index.get(&parent)?;
    let parent_world = world_transform_at_zero(parent_layer, by_index, depth + 1)?;

    let world_x = parent_world.pos.0 + parent_world.scale.0 * own_pos.0;
    let world_y = parent_world.pos.1 + parent_world.scale.1 * own_pos.1;
    let world_sx = parent_world.scale.0 * own_scale.0;
    let world_sy = parent_world.scale.1 * own_scale.1;

    Some(WorldTransform {
        pos: (world_x, world_y),
        scale: (world_sx, world_sy),
    })
}

fn first_xy(prop: &LottieVectorProp) -> Option<(f64, f64)> {
    match prop {
        LottieVectorProp::Static { value } => {
            if value.len() >= 2 {
                Some((value[0], value[1]))
            } else {
                None
            }
        }
        LottieVectorProp::Animated { keyframes } => keyframes.first().and_then(|kf| {
            if kf.start.len() >= 2 {
                Some((kf.start[0], kf.start[1]))
            } else {
                None
            }
        }),
    }
}

fn layer_type_str(layer: &LottieLayer) -> &'static str {
    match layer {
        LottieLayer::Image(_) => "image",
        LottieLayer::Shape(_) => "shape",
        LottieLayer::Null(_) => "null",
    }
}

fn parent_field(parent: Option<i32>) -> Value {
    match parent {
        Some(p) => Value::from(p),
        None => Value::Null,
    }
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::lottie::{
        LottieLayerCommon, LottieScalarProp, LottieShapeLayer, LottieTransform, LottieVectorProp,
    };
    use crate::log::LogLevel;

    fn shape_layer(index: i32, name: &str, pos: [f64; 2], parent: Option<i32>) -> LottieLayer {
        let mut common = LottieLayerCommon::default();
        common.index = index;
        common.name = name.to_string();
        common.parent = parent;
        common.transform = LottieTransform {
            anchor: LottieVectorProp::Static {
                value: vec![0.0, 0.0],
            },
            position: LottieVectorProp::Static {
                value: pos.to_vec(),
            },
            scale: LottieVectorProp::Static {
                value: vec![100.0, 100.0],
            },
            rotation: LottieScalarProp::Static { value: 0.0 },
            opacity: LottieScalarProp::Static { value: 100.0 },
            skew: LottieScalarProp::Static { value: 0.0 },
            skew_axis: LottieScalarProp::Static { value: 0.0 },
        };
        LottieLayer::Shape(LottieShapeLayer {
            common,
            shapes: Vec::new(),
        })
    }

    fn doc_with(layers: Vec<LottieLayer>) -> LottieDoc {
        LottieDoc {
            version: LottieDoc::DEFAULT_VERSION.to_string(),
            frame_rate: 60.0,
            in_point: 0.0,
            out_point: 60.0,
            width: 700.0,
            height: 400.0,
            assets: Vec::new(),
            layers,
        }
    }

    fn warn_entries(logs: Vec<crate::log::LogEntry>) -> Vec<crate::log::LogEntry> {
        logs.into_iter()
            .filter(|e| matches!(e.level, LogLevel::Warn))
            .collect()
    }

    #[test]
    fn passes_when_layer_inside_comp() {
        let mut logs = LogCollector::new(LogLevel::Trace);
        let doc = doc_with(vec![shape_layer(0, "ok", [350.0, 200.0], None)]);
        validate(&doc, &mut logs);
        let warns = warn_entries(logs.into_entries());
        assert!(warns.is_empty(), "expected no warns, got {:?}", warns);
    }

    #[test]
    fn warns_when_layer_far_outside_comp() {
        let mut logs = LogCollector::new(LogLevel::Trace);
        let doc = doc_with(vec![shape_layer(0, "offscreen", [2000.0, 2000.0], None)]);
        validate(&doc, &mut logs);
        let warns = warn_entries(logs.into_entries());
        assert_eq!(warns.len(), 1);
        assert_eq!(warns[0].stage, "validate.position");
    }

    #[test]
    fn parent_scale_pulls_child_back_inside() {
        let mut logs = LogCollector::new(LogLevel::Trace);
        let mut parent = shape_layer(0, "parent", [2.21, -4.37], None);
        if let LottieLayer::Shape(s) = &mut parent {
            s.common.transform.scale = LottieVectorProp::Static {
                value: vec![38.6, 38.6],
            };
        }
        let child = shape_layer(1, "child", [595.0, 697.0], Some(0));
        let doc = doc_with(vec![parent, child]);
        validate(&doc, &mut logs);
        let warns = warn_entries(logs.into_entries());
        assert!(
            warns.is_empty(),
            "child at (595,697) under scale-0.386 parent should be at ~(232,264), got warns {:?}",
            warns
        );
    }

    #[test]
    fn missing_parent_scale_leaves_child_offscreen() {
        let mut logs = LogCollector::new(LogLevel::Trace);
        let parent = shape_layer(0, "parent", [0.0, 0.0], None);
        let child = shape_layer(1, "child_lost", [595.0, 697.0], Some(0));
        let doc = doc_with(vec![parent, child]);
        validate(&doc, &mut logs);
        let warns = warn_entries(logs.into_entries());
        assert_eq!(warns.len(), 1);
        let layer_name = warns[0]
            .fields
            .iter()
            .find(|(k, _)| *k == "layer_name")
            .map(|(_, v)| v.as_str().unwrap_or(""))
            .unwrap_or("");
        assert_eq!(layer_name, "child_lost");
    }

    #[test]
    fn no_parent_chain_cycles_into_infinite_recursion() {
        let mut logs = LogCollector::new(LogLevel::Trace);
        let mut a = shape_layer(0, "a", [0.0, 0.0], Some(1));
        let mut b = shape_layer(1, "b", [0.0, 0.0], Some(0));
        if let (LottieLayer::Shape(sa), LottieLayer::Shape(sb)) = (&mut a, &mut b) {
            sa.common.parent = Some(1);
            sb.common.parent = Some(0);
        }
        let doc = doc_with(vec![a, b]);
        validate(&doc, &mut logs);
        let _ = logs.into_entries();
    }
}
