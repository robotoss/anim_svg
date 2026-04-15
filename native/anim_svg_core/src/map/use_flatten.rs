//! Port of `lib/src/data/mappers/use_flattener.dart`.
//!
//! Resolves `<use xlink:href="#id">` references against the document's
//! `<defs>`, returning a deep-copied tree where every [`SvgUse`] is
//! replaced by the referenced node (wrapped in an [`SvgGroup`] that
//! preserves the use's own transforms and animations).
//!
//! The Dart side surfaces missing refs and >32-level recursion as hard
//! errors. The native port downgrades both to `warn` entries and drops the
//! offending node — this keeps conversion partial-result-friendly and
//! matches the logging convention used by the other mappers.
//!
//! Note: SVG `<use x y>` attributes are baked into `static_transforms` at
//! parse time, so flattening only has to preserve `common` onto the
//! wrapper group — no explicit translate construction here.

use crate::domain::{SvgDefs, SvgDocument, SvgGroup, SvgImage, SvgNode, SvgNodeCommon, SvgUse};
use crate::log::LogCollector;

/// Soft recursion limit mirroring the Dart side. Chains deeper than this
/// are almost always cyclic (`<use>` pointing at itself via a `<g>`), so
/// we log and stop.
pub const MAX_DEPTH: i32 = 32;

/// Mirrors `UseFlattener.flatten`.
pub fn flatten(doc: SvgDocument, logs: &mut LogCollector) -> SvgDocument {
    let SvgDocument {
        width,
        height,
        view_box,
        defs,
        root,
    } = doc;
    let root = flatten_group(root, &defs, 0, logs);
    SvgDocument {
        width,
        height,
        view_box,
        // defs are inlined now — drop them from the output document.
        defs: SvgDefs::default(),
        root,
    }
}

fn flatten_node(node: SvgNode, defs: &SvgDefs, depth: i32, logs: &mut LogCollector) -> Option<SvgNode> {
    if depth > MAX_DEPTH {
        logs.warn(
            "map.use_flatten",
            "use-flatten recursion too deep, dropping subtree",
            &[("depth", (depth as u64).into())],
        );
        return None;
    }
    match node {
        SvgNode::Group(g) => Some(SvgNode::Group(flatten_group(g, defs, depth, logs))),
        SvgNode::Use(u) => flatten_use(u, defs, depth, logs),
        SvgNode::Image(i) => Some(SvgNode::Image(i)),
        SvgNode::Shape(s) => Some(SvgNode::Shape(s)),
    }
}

fn flatten_group(g: SvgGroup, defs: &SvgDefs, depth: i32, logs: &mut LogCollector) -> SvgGroup {
    let SvgGroup {
        common,
        children,
        display_none,
    } = g;
    let mut new_children = Vec::with_capacity(children.len());
    for c in children {
        if let Some(fc) = flatten_node(c, defs, depth + 1, logs) {
            new_children.push(fc);
        }
    }
    SvgGroup {
        common,
        children: new_children,
        display_none,
    }
}

fn flatten_use(u: SvgUse, defs: &SvgDefs, depth: i32, logs: &mut LogCollector) -> Option<SvgNode> {
    let target = match defs.by_id.get(&u.href_id) {
        Some(t) => t.clone(),
        None => {
            logs.warn(
                "map.use_flatten",
                "<use> href not found in <defs>, dropping",
                &[("hrefId", u.href_id.clone().into())],
            );
            return None;
        }
    };
    // Recursively flatten the target so <use> chains collapse.
    let mut resolved = flatten_node(target, defs, depth + 1, logs)?;
    // SVG quirk: <image> tags in <defs> often have no width/height — the size
    // is declared on the <use> that references them. Push the <use>'s size
    // into any zero-sized <image> inside the resolved subtree.
    if let (Some(w), Some(h)) = (u.width, u.height) {
        resolved = apply_size(resolved, w, h);
    }
    // Wrap into a group so the <use>'s own transforms/animations apply on
    // top. `display_none` never carries through <use>; the Dart flattener
    // uses the default `false`.
    let wrapper = SvgGroup {
        common: SvgNodeCommon {
            id: u.common.id,
            static_transforms: u.common.static_transforms,
            animations: u.common.animations,
            filter_id: u.common.filter_id,
            mask_id: u.common.mask_id,
            motion_path: u.common.motion_path,
        },
        children: vec![resolved],
        display_none: false,
    };
    Some(SvgNode::Group(wrapper))
}

fn apply_size(node: SvgNode, width: f64, height: f64) -> SvgNode {
    match node {
        SvgNode::Image(img) => {
            if img.width == 0.0 && img.height == 0.0 {
                SvgNode::Image(SvgImage {
                    common: img.common,
                    href: img.href,
                    width,
                    height,
                })
            } else {
                SvgNode::Image(img)
            }
        }
        SvgNode::Group(g) => {
            let SvgGroup {
                common,
                children,
                display_none,
            } = g;
            let new_children = children
                .into_iter()
                .map(|c| apply_size(c, width, height))
                .collect();
            SvgNode::Group(SvgGroup {
                common,
                children: new_children,
                display_none,
            })
        }
        // SvgUse should not occur after flatten; SvgShape is a no-op.
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        SvgDefs, SvgNodeCommon, SvgShape, SvgShapeKind, SvgStaticTransform, SvgTransformKind,
        SvgViewBox,
    };
    use crate::log::LogLevel;
    use std::collections::BTreeMap;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn mk_rect(id: &str) -> SvgNode {
        SvgNode::Shape(SvgShape {
            common: SvgNodeCommon {
                id: Some(id.to_string()),
                ..Default::default()
            },
            kind: SvgShapeKind::Rect,
            width: 10.0,
            height: 10.0,
            ..Default::default()
        })
    }

    fn mk_doc(root: SvgGroup, defs: SvgDefs) -> SvgDocument {
        SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: SvgViewBox {
                x: 0.0,
                y: 0.0,
                w: 100.0,
                h: 100.0,
            },
            defs,
            root,
        }
    }

    #[test]
    fn use_resolves_referenced_node() {
        let mut logs = mk_logs();
        let mut by_id: BTreeMap<String, SvgNode> = BTreeMap::new();
        by_id.insert("r1".to_string(), mk_rect("r1"));
        let defs = SvgDefs {
            by_id,
            ..Default::default()
        };
        let root = SvgGroup {
            children: vec![SvgNode::Use(SvgUse {
                common: SvgNodeCommon::default(),
                href_id: "r1".to_string(),
                width: None,
                height: None,
            })],
            ..Default::default()
        };
        let out = flatten(mk_doc(root, defs), &mut logs);
        // Root has one child: a wrapper group containing the resolved rect.
        assert_eq!(out.root.children.len(), 1);
        let wrapper = match &out.root.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!("expected wrapper group"),
        };
        assert_eq!(wrapper.children.len(), 1);
        matches!(&wrapper.children[0], SvgNode::Shape(_));
        // defs are cleared on the output.
        assert!(out.defs.by_id.is_empty());
    }

    #[test]
    fn use_preserves_static_transforms_onto_wrapper() {
        // In the parse stage `<use x y>` lowers to an entry in
        // `static_transforms`. The flattener must preserve that on the
        // wrapper group so the rendered position matches.
        let mut logs = mk_logs();
        let mut by_id: BTreeMap<String, SvgNode> = BTreeMap::new();
        by_id.insert("r1".to_string(), mk_rect("r1"));
        let defs = SvgDefs {
            by_id,
            ..Default::default()
        };
        let translate = SvgStaticTransform {
            kind: SvgTransformKind::Translate,
            values: vec![5.0, 7.0],
        };
        let root = SvgGroup {
            children: vec![SvgNode::Use(SvgUse {
                common: SvgNodeCommon {
                    id: Some("u1".to_string()),
                    static_transforms: vec![translate.clone()],
                    ..Default::default()
                },
                href_id: "r1".to_string(),
                width: None,
                height: None,
            })],
            ..Default::default()
        };
        let out = flatten(mk_doc(root, defs), &mut logs);
        let wrapper = match &out.root.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!(),
        };
        assert_eq!(wrapper.common.id.as_deref(), Some("u1"));
        assert_eq!(wrapper.common.static_transforms.len(), 1);
        assert_eq!(
            wrapper.common.static_transforms[0].kind,
            SvgTransformKind::Translate
        );
        assert_eq!(wrapper.common.static_transforms[0].values, vec![5.0, 7.0]);
    }

    #[test]
    fn missing_ref_logs_and_skips() {
        let mut logs = mk_logs();
        let defs = SvgDefs::default();
        let root = SvgGroup {
            children: vec![
                SvgNode::Use(SvgUse {
                    common: SvgNodeCommon::default(),
                    href_id: "nope".to_string(),
                    width: None,
                    height: None,
                }),
                mk_rect("keeper"),
            ],
            ..Default::default()
        };
        let out = flatten(mk_doc(root, defs), &mut logs);
        // The missing <use> is dropped; the sibling rect survives.
        assert_eq!(out.root.children.len(), 1);
        let entries = logs.into_entries();
        assert!(entries
            .iter()
            .any(|e| e.stage == "map.use_flatten" && e.message.contains("not found")));
    }

    #[test]
    fn use_size_is_applied_to_zero_sized_image_in_defs() {
        let mut logs = mk_logs();
        let mut by_id: BTreeMap<String, SvgNode> = BTreeMap::new();
        by_id.insert(
            "img".to_string(),
            SvgNode::Image(SvgImage {
                common: SvgNodeCommon::default(),
                href: "data:image/png;base64,iVBOR".to_string(),
                width: 0.0,
                height: 0.0,
            }),
        );
        let defs = SvgDefs {
            by_id,
            ..Default::default()
        };
        let root = SvgGroup {
            children: vec![SvgNode::Use(SvgUse {
                common: SvgNodeCommon::default(),
                href_id: "img".to_string(),
                width: Some(48.0),
                height: Some(24.0),
            })],
            ..Default::default()
        };
        let out = flatten(mk_doc(root, defs), &mut logs);
        let wrapper = match &out.root.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!(),
        };
        match &wrapper.children[0] {
            SvgNode::Image(i) => {
                assert_eq!(i.width, 48.0);
                assert_eq!(i.height, 24.0);
            }
            _ => panic!("expected image"),
        }
    }

    #[test]
    fn use_chain_collapses_transitively() {
        // <use href="#a"> where a is itself a <use href="#b">.
        let mut logs = mk_logs();
        let mut by_id: BTreeMap<String, SvgNode> = BTreeMap::new();
        by_id.insert("b".to_string(), mk_rect("b"));
        by_id.insert(
            "a".to_string(),
            SvgNode::Use(SvgUse {
                common: SvgNodeCommon::default(),
                href_id: "b".to_string(),
                width: None,
                height: None,
            }),
        );
        let defs = SvgDefs {
            by_id,
            ..Default::default()
        };
        let root = SvgGroup {
            children: vec![SvgNode::Use(SvgUse {
                common: SvgNodeCommon::default(),
                href_id: "a".to_string(),
                width: None,
                height: None,
            })],
            ..Default::default()
        };
        let out = flatten(mk_doc(root, defs), &mut logs);
        // Outer wrapper (for <use href=a>) → inner wrapper (for <use href=b>)
        // → the rect shape.
        let outer = match &out.root.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!(),
        };
        let inner = match &outer.children[0] {
            SvgNode::Group(g) => g,
            _ => panic!(),
        };
        matches!(&inner.children[0], SvgNode::Shape(_));
    }
}
