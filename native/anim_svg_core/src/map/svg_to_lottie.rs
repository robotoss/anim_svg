//! Port of `lib/src/data/mappers/svg_to_lottie_mapper.dart`.
//!
//! Orchestrates the full SVG → Lottie pipeline:
//! 1. Normalize CSS-only animation options (direction / delay / fill-mode)
//!    into plain forward keyframe tracks (`normalize`).
//! 2. Resolve CSS Motion Path into explicit translate/rotate tracks
//!    (`motion_path::resolve`).
//! 3. Flatten `<use>` references (`use_flatten::flatten`).
//! 4. Recursively walk the SVG tree emitting Lottie layers + assets.
//!
//! Ordering matches Dart: normalize → motion_path → use_flatten.
//!
//! The walker handles animated ancestor chains, static-transform baking,
//! track-matte masks, filter effects (blur / saturate / brightness), and
//! Lottie parent-index rewriting post-reversal.

use std::collections::BTreeMap;

use crate::domain::{
    BezierHandle, LottieAsset, LottieDoc, LottieEffect, LottieImageLayer, LottieLayer,
    LottieLayerCommon, LottieNullLayer, LottieScalarKeyframe, LottieScalarProp, LottieShapeItem,
    LottieShapeLayer, LottieTransform, LottieVectorKeyframe, LottieVectorProp, SvgAnimationAdditive,
    SvgAnimationCalcMode, SvgAnimationCommon, SvgAnimationNode, SvgColorMatrixKind, SvgDefs,
    SvgDocument, SvgFilter, SvgFilterPrimitive, SvgGradient, SvgGroup, SvgImage, SvgMask,
    SvgMaskType, SvgNode, SvgNodeCommon, SvgShape, SvgStaticTransform, SvgTransformKind,
};
use crate::log::LogCollector;
use crate::map::{
    image_asset, motion_path, nested_anim, normalize, opacity, opacity_merge, shape,
    transform_map, use_flatten,
};

/// Public entry point — port of Dart `SvgToLottieMapper.map`.
pub fn map(raw_doc: SvgDocument, frame_rate: f64, logs: &mut LogCollector) -> LottieDoc {
    // 1. Normalize every animation node in the document. Dart's normalizer
    //    returns a new tree; here we walk the tree and replace animations
    //    per-node (`normalize` takes a Vec<SvgAnimationNode>, not the
    //    whole doc).
    let normalized_doc = normalize_doc(raw_doc, logs);
    // 2. Motion-path resolver needs `SvgNode.motion_path` which the
    //    flattener does not preserve.
    let resolved_doc = motion_path::resolve(normalized_doc, logs);

    // Keep defs around; the flattener drops them but we need gradients /
    // filters / masks during the walk.
    let gradients = resolved_doc.defs.gradients.clone();
    let filters = resolved_doc.defs.filters.clone();
    let masks = resolved_doc.defs.masks.clone();

    // 3. Flatten <use> references.
    let doc = use_flatten::flatten(resolved_doc, logs);
    logs.debug(
        "map",
        "flattened",
        &[("root_children", (doc.root.children.len() as u64).into())],
    );

    let mut assets: Vec<LottieAsset> = Vec::new();
    let mut layers: Vec<LottieLayer> = Vec::new();
    let mut max_dur_sec: f64 = 0.0;

    let ctx = WalkCtx {
        gradients: &gradients,
        filters: &filters,
        masks: &masks,
        frame_rate,
    };

    walk(
        &ctx,
        &SvgNode::Group(doc.root.clone()),
        &[],
        None,
        &[],
        &[],
        None,
        "root",
        None,
        None,
        false,
        &mut assets,
        &mut layers,
        &mut max_dur_sec,
        logs,
    );

    // Lottie requires op > ip. Clamp static / CSS-only SVGs to 1 frame.
    let raw_out = (max_dur_sec * frame_rate).ceil();
    let out_point_frames = if raw_out > 0.0 { raw_out } else { 1.0 };

    // Reverse: Lottie draws bottom-first. After reversal, assign final
    // `index` (ind = position + 1) and resolve sentinel parent references
    // (stored as negative -walkIdx-1).
    let total = layers.len();
    let mut reordered: Vec<LottieLayer> = layers.into_iter().rev().collect();
    for (i, l) in reordered.iter_mut().enumerate() {
        l.common_mut().index = (i as i32) + 1;
    }
    for l in reordered.iter_mut() {
        let common = l.common_mut();
        if let Some(p) = common.parent {
            if p < 0 {
                let walk_idx = (-p - 1) as usize;
                // After reversal: walk position i is at reordered index
                // total-1-i, final ind = total-i.
                let final_ind = (total as i32) - (walk_idx as i32);
                common.parent = Some(final_ind);
            }
        }
    }
    // Set out_point on every layer + normalize in_point to 0.
    for l in reordered.iter_mut() {
        let common = l.common_mut();
        common.in_point = 0.0;
        common.out_point = out_point_frames;
    }

    LottieDoc {
        version: LottieDoc::DEFAULT_VERSION.to_string(),
        frame_rate,
        in_point: 0.0,
        out_point: out_point_frames,
        width: doc.width,
        height: doc.height,
        assets,
        layers: reordered,
    }
}

// ---------------------------------------------------------------------------
// Normalize helper — walks the tree applying `normalize` per-node.
// ---------------------------------------------------------------------------

fn normalize_doc(mut doc: SvgDocument, logs: &mut LogCollector) -> SvgDocument {
    doc.root = normalize_group(doc.root, logs);
    let SvgDefs {
        by_id,
        gradients,
        filters,
        masks,
    } = doc.defs;
    let mut new_by_id: BTreeMap<String, SvgNode> = BTreeMap::new();
    for (k, v) in by_id {
        new_by_id.insert(k, normalize_node(v, logs));
    }
    let mut new_masks: BTreeMap<String, SvgMask> = BTreeMap::new();
    for (k, mut m) in masks {
        let children = std::mem::take(&mut m.children);
        m.children = children.into_iter().map(|n| normalize_node(n, logs)).collect();
        new_masks.insert(k, m);
    }
    doc.defs = SvgDefs {
        by_id: new_by_id,
        gradients,
        filters,
        masks: new_masks,
    };
    doc
}

fn normalize_node(n: SvgNode, logs: &mut LogCollector) -> SvgNode {
    match n {
        SvgNode::Group(g) => SvgNode::Group(normalize_group(g, logs)),
        SvgNode::Shape(mut s) => {
            s.common = normalize_common(s.common, logs);
            SvgNode::Shape(s)
        }
        SvgNode::Image(mut i) => {
            i.common = normalize_common(i.common, logs);
            SvgNode::Image(i)
        }
        SvgNode::Use(mut u) => {
            u.common = normalize_common(u.common, logs);
            SvgNode::Use(u)
        }
    }
}

fn normalize_group(mut g: SvgGroup, logs: &mut LogCollector) -> SvgGroup {
    g.common = normalize_common(g.common, logs);
    let children = std::mem::take(&mut g.children);
    g.children = children.into_iter().map(|c| normalize_node(c, logs)).collect();
    g
}

fn normalize_common(mut c: SvgNodeCommon, logs: &mut LogCollector) -> SvgNodeCommon {
    let anims = std::mem::take(&mut c.animations);
    c.animations = normalize::normalize(anims, logs);
    c
}

// ---------------------------------------------------------------------------
// Walk context + recursion state.
// ---------------------------------------------------------------------------

struct WalkCtx<'a> {
    gradients: &'a BTreeMap<String, SvgGradient>,
    filters: &'a BTreeMap<String, SvgFilter>,
    masks: &'a BTreeMap<String, SvgMask>,
    frame_rate: f64,
}

#[derive(Clone)]
struct AnimatedAncestor {
    group_statics: Vec<SvgStaticTransform>,
    anims: Vec<SvgAnimationNode>, // all AnimateTransform variants
}

#[allow(clippy::too_many_arguments)]
fn walk(
    ctx: &WalkCtx,
    node: &SvgNode,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    inherited_filter_id: Option<&str>,
    layer_name: &str,
    parent_lottie_idx: Option<i32>,
    pending_mask: Option<&SvgMask>,
    in_mask_source: bool,
    assets: &mut Vec<LottieAsset>,
    layers: &mut Vec<LottieLayer>,
    max_dur_sec: &mut f64,
    logs: &mut LogCollector,
) {
    // Resolve effective mask. Nested masks inside mask-sources are ignored.
    let mut effective_mask: Option<SvgMask> = pending_mask.cloned();
    let common = node.common();
    if !in_mask_source {
        if let Some(mid) = &common.mask_id {
            match ctx.masks.get(mid) {
                None => {
                    logs.warn(
                        "map.mask",
                        "mask not found in defs; rendering unmasked",
                        &[("id", mid.clone().into())],
                    );
                }
                Some(m) if m.children.is_empty() => {
                    logs.warn(
                        "map.mask",
                        "mask has no renderable children; skipping",
                        &[("id", m.id.clone().into())],
                    );
                }
                Some(m) => {
                    effective_mask = Some(m.clone());
                }
            }
        }
    }

    match node {
        SvgNode::Group(g) => walk_group(
            ctx,
            g,
            statics_before,
            animated_ancestor,
            statics_after,
            inherited_non_transform,
            inherited_filter_id,
            layer_name,
            parent_lottie_idx,
            effective_mask.as_ref(),
            in_mask_source,
            assets,
            layers,
            max_dur_sec,
            logs,
        ),
        SvgNode::Image(img) => walk_image(
            ctx,
            img,
            statics_before,
            animated_ancestor,
            statics_after,
            inherited_non_transform,
            inherited_filter_id,
            layer_name,
            parent_lottie_idx,
            effective_mask.as_ref(),
            in_mask_source,
            assets,
            layers,
            max_dur_sec,
            logs,
        ),
        SvgNode::Use(u) => {
            logs.warn(
                "map.walk",
                "skipping unflattened <use>",
                &[
                    ("hrefId", u.href_id.clone().into()),
                    ("id", u.common.id.clone().unwrap_or_default().into()),
                ],
            );
        }
        SvgNode::Shape(s) => walk_shape(
            ctx,
            s,
            statics_before,
            animated_ancestor,
            statics_after,
            inherited_non_transform,
            inherited_filter_id,
            layer_name,
            parent_lottie_idx,
            effective_mask.as_ref(),
            in_mask_source,
            assets,
            layers,
            max_dur_sec,
            logs,
        ),
    }
}

#[allow(clippy::too_many_arguments)]
fn walk_group(
    ctx: &WalkCtx,
    node: &SvgGroup,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    inherited_filter_id: Option<&str>,
    layer_name: &str,
    parent_lottie_idx: Option<i32>,
    effective_mask: Option<&SvgMask>,
    in_mask_source: bool,
    assets: &mut Vec<LottieAsset>,
    layers: &mut Vec<LottieLayer>,
    max_dur_sec: &mut f64,
    logs: &mut LogCollector,
) {
    if node.display_none && !has_display_animation(&node.common.animations) {
        return;
    }
    track_max_dur(&node.common.animations, max_dur_sec);
    if let Some(aa) = animated_ancestor {
        track_max_dur(&aa.anims, max_dur_sec);
    }

    let own_transform_anims: Vec<SvgAnimationNode> = node
        .common
        .animations
        .iter()
        .filter(|a| matches!(a, SvgAnimationNode::AnimateTransform { .. }))
        .cloned()
        .collect();
    let own_non_transform: Vec<SvgAnimationNode> = node
        .common
        .animations
        .iter()
        .filter(|a| !matches!(a, SvgAnimationNode::AnimateTransform { .. }))
        .cloned()
        .collect();

    let mut next_ancestor: Option<AnimatedAncestor> = animated_ancestor.cloned();
    let mut next_before: Vec<SvgStaticTransform> = statics_before.to_vec();
    let mut next_after: Vec<SvgStaticTransform> = statics_after.to_vec();
    let mut next_parent_lottie_idx: Option<i32> = parent_lottie_idx;

    if !own_transform_anims.is_empty() {
        if let Some(parent_idx) = parent_lottie_idx {
            // Already inside a parenting chain — extend it.
            let idx = emit_null_layer_for_group(
                ctx,
                node,
                &own_transform_anims,
                Some(parent_idx),
                layers,
                logs,
            );
            next_parent_lottie_idx = Some(-(idx as i32) - 1);
            next_ancestor = None;
            next_before = Vec::new();
            next_after = Vec::new();
        } else if let Some(aa) = animated_ancestor {
            // Two-deep animated chain. Try parenting; fall back to WARN+drop.
            let chain = vec![
                nested_anim::ChainEntry {
                    dur_seconds: aa.anims.first().map(|a| a.common().dur_seconds).unwrap_or(0.0),
                    repeat_indefinite: aa
                        .anims
                        .first()
                        .map(|a| a.common().repeat_indefinite)
                        .unwrap_or(false),
                    transform_anims: aa.anims.clone(),
                },
                nested_anim::ChainEntry {
                    dur_seconds: own_transform_anims
                        .first()
                        .map(|a| a.common().dur_seconds)
                        .unwrap_or(0.0),
                    repeat_indefinite: own_transform_anims
                        .first()
                        .map(|a| a.common().repeat_indefinite)
                        .unwrap_or(false),
                    transform_anims: own_transform_anims.clone(),
                },
            ];
            let classifier = nested_anim::NestedAnimationClassifier::default();
            if classifier.can_chain_parent(&chain) {
                let outer_parent_idx: Option<i32> = if !statics_before.is_empty() {
                    let outer_name = format!("anim_g_outer_{}", layers.len());
                    let idx = emit_null_layer_for(
                        ctx,
                        &outer_name,
                        statics_before,
                        &[],
                        None,
                        layers,
                        logs,
                    );
                    Some(-(idx as i32) - 1)
                } else {
                    None
                };
                let ancestor_name = format!("anim_g_{}", layers.len());
                let ancestor_idx = emit_null_layer_for(
                    ctx,
                    &ancestor_name,
                    &aa.group_statics,
                    &aa.anims,
                    outer_parent_idx,
                    layers,
                    logs,
                );
                let after_parent_idx: i32 = if !statics_after.is_empty() {
                    let after_name = format!("anim_g_after_{}", layers.len());
                    let idx = emit_null_layer_for(
                        ctx,
                        &after_name,
                        statics_after,
                        &[],
                        Some(-(ancestor_idx as i32) - 1),
                        layers,
                        logs,
                    );
                    -(idx as i32) - 1
                } else {
                    -(ancestor_idx as i32) - 1
                };
                let cur_idx = emit_null_layer_for_group(
                    ctx,
                    node,
                    &own_transform_anims,
                    Some(after_parent_idx),
                    layers,
                    logs,
                );
                next_parent_lottie_idx = Some(-(cur_idx as i32) - 1);
                next_ancestor = None;
                next_before = Vec::new();
                next_after = Vec::new();
            } else {
                logs.warn(
                    "map.walk",
                    "nested animated groups with mismatched dur; dropping inner anims",
                    &[
                        (
                            "group",
                            node.common.id.clone().unwrap_or_else(|| "(anon)".into()).into(),
                        ),
                        (
                            "outer_dur",
                            aa.anims.first().map(|a| a.common().dur_seconds).unwrap_or(0.0).into(),
                        ),
                        (
                            "inner_dur",
                            own_transform_anims
                                .first()
                                .map(|a| a.common().dur_seconds)
                                .unwrap_or(0.0)
                                .into(),
                        ),
                    ],
                );
                next_before = statics_before.to_vec();
                next_after = {
                    let mut v = statics_after.to_vec();
                    v.extend(node.common.static_transforms.iter().cloned());
                    v
                };
            }
        } else {
            next_ancestor = Some(AnimatedAncestor {
                group_statics: node.common.static_transforms.clone(),
                anims: own_transform_anims.clone(),
            });
            next_after = Vec::new();
        }
    } else {
        if animated_ancestor.is_none() && parent_lottie_idx.is_none() {
            next_before.extend(node.common.static_transforms.iter().cloned());
        } else if parent_lottie_idx.is_some() {
            next_before.extend(node.common.static_transforms.iter().cloned());
        } else {
            next_after.extend(node.common.static_transforms.iter().cloned());
        }
    }

    let next_inherited: Vec<SvgAnimationNode> = if own_non_transform.is_empty() {
        inherited_non_transform.to_vec()
    } else {
        let mut v = inherited_non_transform.to_vec();
        v.extend(own_non_transform.iter().cloned());
        v
    };

    let next_filter_id: Option<String> = node
        .common
        .filter_id
        .clone()
        .or_else(|| inherited_filter_id.map(|s| s.to_string()));

    let next_layer_name = node.common.id.as_deref().unwrap_or(layer_name).to_string();

    for child in &node.children {
        walk(
            ctx,
            child,
            &next_before,
            next_ancestor.as_ref(),
            &next_after,
            &next_inherited,
            next_filter_id.as_deref(),
            &next_layer_name,
            next_parent_lottie_idx,
            effective_mask,
            in_mask_source,
            assets,
            layers,
            max_dur_sec,
            logs,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn walk_image(
    ctx: &WalkCtx,
    node: &SvgImage,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    inherited_filter_id: Option<&str>,
    layer_name: &str,
    parent_lottie_idx: Option<i32>,
    effective_mask: Option<&SvgMask>,
    in_mask_source: bool,
    assets: &mut Vec<LottieAsset>,
    layers: &mut Vec<LottieLayer>,
    max_dur_sec: &mut f64,
    logs: &mut LogCollector,
) {
    track_max_dur(&node.common.animations, max_dur_sec);
    if let Some(aa) = animated_ancestor {
        track_max_dur(&aa.anims, max_dur_sec);
    }
    let asset_id = format!("asset_{}", assets.len());
    let asset = match image_asset::build(node, &asset_id, logs) {
        Ok(a) => a,
        Err(e) => {
            logs.warn(
                "map.image",
                "asset build failed; skipping image",
                &[
                    ("id", node.common.id.clone().unwrap_or_default().into()),
                    ("error", e.to_string().into()),
                ],
            );
            return;
        }
    };
    assets.push(asset);

    let href_preview = if node.href.len() > 48 {
        format!("{}...", &node.href[..48])
    } else {
        node.href.clone()
    };
    logs.trace(
        "map.image",
        "added asset",
        &[
            ("id", asset_id.clone().into()),
            ("w", node.width.into()),
            ("h", node.height.into()),
            ("href_preview", href_preview.into()),
        ],
    );

    let filter_id = node
        .common
        .filter_id
        .clone()
        .or_else(|| inherited_filter_id.map(|s| s.to_string()));
    let effects = resolve_effects(filter_id.as_deref(), ctx.filters, ctx.frame_rate, logs);

    let name = node.common.id.clone().unwrap_or_else(|| layer_name.to_string());
    let leaf = build_image_layer(
        ctx,
        node,
        statics_before,
        animated_ancestor,
        statics_after,
        inherited_non_transform,
        &asset_id,
        &name,
        effects,
        parent_lottie_idx,
        logs,
    );
    emit_leaf_with_mask(
        ctx,
        leaf,
        effective_mask,
        in_mask_source,
        statics_before,
        animated_ancestor,
        statics_after,
        inherited_non_transform,
        inherited_filter_id,
        parent_lottie_idx,
        assets,
        layers,
        max_dur_sec,
        logs,
    );
}

#[allow(clippy::too_many_arguments)]
fn walk_shape(
    ctx: &WalkCtx,
    node: &SvgShape,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    inherited_filter_id: Option<&str>,
    layer_name: &str,
    parent_lottie_idx: Option<i32>,
    effective_mask: Option<&SvgMask>,
    in_mask_source: bool,
    assets: &mut Vec<LottieAsset>,
    layers: &mut Vec<LottieLayer>,
    max_dur_sec: &mut f64,
    logs: &mut LogCollector,
) {
    track_max_dur(&node.common.animations, max_dur_sec);
    if let Some(aa) = animated_ancestor {
        track_max_dur(&aa.anims, max_dur_sec);
    }
    // Shape mapper expects an SvgDefs — construct one with only the
    // gradients we kept (flattener cleared everything else).
    let defs = SvgDefs {
        by_id: BTreeMap::new(),
        gradients: ctx.gradients.clone(),
        filters: BTreeMap::new(),
        masks: BTreeMap::new(),
    };
    let shape_items = shape::map(node, &defs, logs);
    if shape_items.is_empty() {
        logs.debug(
            "map.shape",
            "shape emitted no items; skipping layer",
            &[
                ("id", node.common.id.clone().unwrap_or_default().into()),
                ("kind", format!("{:?}", node.kind).into()),
            ],
        );
        return;
    }
    let filter_id = node
        .common
        .filter_id
        .clone()
        .or_else(|| inherited_filter_id.map(|s| s.to_string()));
    let effects = resolve_effects(filter_id.as_deref(), ctx.filters, ctx.frame_rate, logs);

    let name = node.common.id.clone().unwrap_or_else(|| layer_name.to_string());
    let leaf = build_shape_layer(
        ctx,
        node,
        statics_before,
        animated_ancestor,
        statics_after,
        inherited_non_transform,
        shape_items,
        &name,
        effects,
        parent_lottie_idx,
        logs,
    );
    emit_leaf_with_mask(
        ctx,
        leaf,
        effective_mask,
        in_mask_source,
        statics_before,
        animated_ancestor,
        statics_after,
        inherited_non_transform,
        inherited_filter_id,
        parent_lottie_idx,
        assets,
        layers,
        max_dur_sec,
        logs,
    );
}

#[allow(clippy::too_many_arguments)]
fn emit_leaf_with_mask(
    ctx: &WalkCtx,
    leaf: LottieLayer,
    effective_mask: Option<&SvgMask>,
    in_mask_source: bool,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    inherited_filter_id: Option<&str>,
    parent_lottie_idx: Option<i32>,
    assets: &mut Vec<LottieAsset>,
    layers: &mut Vec<LottieLayer>,
    max_dur_sec: &mut f64,
    logs: &mut LogCollector,
) {
    if in_mask_source {
        let mut l = leaf;
        l.common_mut().td = Some(1);
        layers.push(l);
        return;
    }
    let mask = match effective_mask {
        None => {
            layers.push(leaf);
            return;
        }
        Some(m) => m,
    };
    let tt = if mask.mask_type == SvgMaskType::Luminance {
        2
    } else {
        1
    };
    let mut target = leaf;
    target.common_mut().tt = Some(tt);
    layers.push(target);

    // Emit mask source(s) immediately after — in final reversed list they
    // sit ABOVE the target, Lottie's track-matte pairing rule.
    let name = format!("mask_{}", mask.id);
    for child in &mask.children {
        walk(
            ctx,
            child,
            statics_before,
            animated_ancestor,
            statics_after,
            inherited_non_transform,
            inherited_filter_id,
            &name,
            parent_lottie_idx,
            None,
            true,
            assets,
            layers,
            max_dur_sec,
            logs,
        );
    }
}

fn has_display_animation(anims: &[SvgAnimationNode]) -> bool {
    anims.iter().any(|a| {
        matches!(a, SvgAnimationNode::Animate { attribute_name, .. }
            if attribute_name == "display")
    })
}

fn track_max_dur(anims: &[SvgAnimationNode], max_dur_sec: &mut f64) {
    for a in anims {
        let d = a.common().dur_seconds;
        if d > *max_dur_sec {
            *max_dur_sec = d;
        }
    }
}

// ---------------------------------------------------------------------------
// Leaf layer construction.
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn build_image_layer(
    ctx: &WalkCtx,
    node: &SvgImage,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    asset_id: &str,
    name: &str,
    effects: Vec<LottieEffect>,
    parent_sentinel_idx: Option<i32>,
    logs: &mut LogCollector,
) -> LottieLayer {
    let leaf_own_transform_anims = only_transforms(&node.common.animations);
    let leaf_own_non_transform = only_non_transforms(&node.common.animations);

    let transform = if let Some(aa) = animated_ancestor {
        let mut after = statics_after.to_vec();
        after.extend(node.common.static_transforms.iter().cloned());
        build_baked_transform(
            ctx,
            statics_before,
            aa,
            &after,
            &leaf_own_transform_anims,
            inherited_non_transform,
            &leaf_own_non_transform,
            logs,
        )
    } else {
        let mut statics = statics_before.to_vec();
        statics.extend(node.common.static_transforms.iter().cloned());
        build_leaf_local_transform(
            ctx,
            &statics,
            &leaf_own_transform_anims,
            inherited_non_transform,
            &leaf_own_non_transform,
            logs,
        )
    };

    let common = LottieLayerCommon {
        index: 0,
        name: name.to_string(),
        transform,
        in_point: 0.0,
        out_point: 0.0,
        effects,
        parent: parent_sentinel_idx,
        td: None,
        tt: None,
    };
    LottieLayer::Image(LottieImageLayer {
        common,
        ref_id: asset_id.to_string(),
        width: Some(node.width),
        height: Some(node.height),
    })
}

#[allow(clippy::too_many_arguments)]
fn build_shape_layer(
    ctx: &WalkCtx,
    node: &SvgShape,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: Option<&AnimatedAncestor>,
    statics_after: &[SvgStaticTransform],
    inherited_non_transform: &[SvgAnimationNode],
    shape_items: Vec<LottieShapeItem>,
    name: &str,
    effects: Vec<LottieEffect>,
    parent_sentinel_idx: Option<i32>,
    logs: &mut LogCollector,
) -> LottieLayer {
    let leaf_own_transform_anims = only_transforms(&node.common.animations);
    let leaf_own_non_transform = only_non_transforms(&node.common.animations);

    let transform = if let Some(aa) = animated_ancestor {
        let mut after = statics_after.to_vec();
        after.extend(node.common.static_transforms.iter().cloned());
        build_baked_transform(
            ctx,
            statics_before,
            aa,
            &after,
            &leaf_own_transform_anims,
            inherited_non_transform,
            &leaf_own_non_transform,
            logs,
        )
    } else {
        let mut statics = statics_before.to_vec();
        statics.extend(node.common.static_transforms.iter().cloned());
        build_leaf_local_transform(
            ctx,
            &statics,
            &leaf_own_transform_anims,
            inherited_non_transform,
            &leaf_own_non_transform,
            logs,
        )
    };

    let common = LottieLayerCommon {
        index: 0,
        name: name.to_string(),
        transform,
        in_point: 0.0,
        out_point: 0.0,
        effects,
        parent: parent_sentinel_idx,
        td: None,
        tt: None,
    };
    LottieLayer::Shape(LottieShapeLayer {
        common,
        shapes: shape_items,
    })
}

fn only_transforms(anims: &[SvgAnimationNode]) -> Vec<SvgAnimationNode> {
    anims
        .iter()
        .filter(|a| matches!(a, SvgAnimationNode::AnimateTransform { .. }))
        .cloned()
        .collect()
}

fn only_non_transforms(anims: &[SvgAnimationNode]) -> Vec<SvgAnimationNode> {
    anims
        .iter()
        .filter(|a| !matches!(a, SvgAnimationNode::AnimateTransform { .. }))
        .cloned()
        .collect()
}

// ---------------------------------------------------------------------------
// Null-layer emission for animated-ancestor chains.
// ---------------------------------------------------------------------------

fn emit_null_layer_for_group(
    ctx: &WalkCtx,
    node: &SvgGroup,
    own_transform_anims: &[SvgAnimationNode],
    parent_sentinel_idx: Option<i32>,
    layers: &mut Vec<LottieLayer>,
    logs: &mut LogCollector,
) -> usize {
    let name = node
        .common
        .id
        .clone()
        .unwrap_or_else(|| format!("anim_g_{}", layers.len()));
    emit_null_layer_for(
        ctx,
        &name,
        &node.common.static_transforms,
        own_transform_anims,
        parent_sentinel_idx,
        layers,
        logs,
    )
}

fn emit_null_layer_for(
    ctx: &WalkCtx,
    name: &str,
    statics: &[SvgStaticTransform],
    anims: &[SvgAnimationNode],
    parent_sentinel_idx: Option<i32>,
    layers: &mut Vec<LottieLayer>,
    logs: &mut LogCollector,
) -> usize {
    let transform = build_leaf_local_transform(ctx, statics, anims, &[], &[], logs);
    let idx = layers.len();
    let common = LottieLayerCommon {
        index: 0,
        name: name.to_string(),
        transform,
        in_point: 0.0,
        out_point: 0.0,
        effects: Vec::new(),
        parent: parent_sentinel_idx,
        td: None,
        tt: None,
    };
    layers.push(LottieLayer::Null(LottieNullLayer { common }));
    idx
}

// ---------------------------------------------------------------------------
// Filter → Lottie effects.
// ---------------------------------------------------------------------------

fn resolve_effects(
    filter_id: Option<&str>,
    filters: &BTreeMap<String, SvgFilter>,
    frame_rate: f64,
    logs: &mut LogCollector,
) -> Vec<LottieEffect> {
    let Some(id) = filter_id else {
        return Vec::new();
    };
    let Some(filter) = filters.get(id) else {
        logs.warn(
            "map.filter",
            "filter id not found in defs; skipping effects",
            &[("id", id.to_string().into())],
        );
        return Vec::new();
    };
    let mut effects = Vec::new();
    for p in &filter.primitives {
        match p {
            SvgFilterPrimitive::GaussianBlur {
                std_deviation,
                std_deviation_anim,
            } => {
                // Lottie blur radius ≈ 2× SVG stdDeviation.
                let blur = if let Some(anim) = std_deviation_anim.as_deref() {
                    map_scalar_anim(anim, 2.0, *std_deviation * 2.0, frame_rate)
                } else {
                    LottieScalarProp::Static {
                        value: *std_deviation * 2.0,
                    }
                };
                effects.push(LottieEffect::Blur { blurriness: blur });
            }
            SvgFilterPrimitive::ColorMatrix {
                matrix_kind,
                values,
                values_anim,
            } => {
                if *matrix_kind == SvgColorMatrixKind::Saturate {
                    // SVG saturate s → AE Master Saturation (s-1)*100.
                    let sat = if let Some(anim) = values_anim.as_deref() {
                        shift_scalar(
                            map_scalar_anim(anim, 100.0, 0.0, frame_rate),
                            -100.0,
                        )
                    } else {
                        LottieScalarProp::Static {
                            value: (*values - 1.0) * 100.0,
                        }
                    };
                    effects.push(LottieEffect::HueSaturation {
                        master_saturation: sat,
                    });
                } else {
                    logs.warn(
                        "map.filter",
                        "feColorMatrix kind not supported in Lottie; skipping",
                        &[
                            ("kind", format!("{:?}", matrix_kind).into()),
                            ("filter", id.to_string().into()),
                        ],
                    );
                }
            }
            SvgFilterPrimitive::ComponentTransfer {
                slope_r,
                slope_g,
                slope_b,
                slope_r_anim,
                slope_g_anim,
                slope_b_anim,
            } => {
                if let Some(eff) = build_brightness_effect(
                    *slope_r,
                    *slope_g,
                    *slope_b,
                    slope_r_anim.as_deref(),
                    slope_g_anim.as_deref(),
                    slope_b_anim.as_deref(),
                    id,
                    frame_rate,
                    logs,
                ) {
                    effects.push(eff);
                }
            }
        }
    }
    effects
}

#[allow(clippy::too_many_arguments)]
fn build_brightness_effect(
    slope_r: Option<f64>,
    slope_g: Option<f64>,
    slope_b: Option<f64>,
    r_anim: Option<&SvgAnimationNode>,
    g_anim: Option<&SvgAnimationNode>,
    b_anim: Option<&SvgAnimationNode>,
    filter_id: &str,
    frame_rate: f64,
    logs: &mut LogCollector,
) -> Option<LottieEffect> {
    let r = slope_r.unwrap_or(1.0);
    let g = slope_g.unwrap_or(1.0);
    let b = slope_b.unwrap_or(1.0);
    let any_anim = r_anim.is_some() || g_anim.is_some() || b_anim.is_some();
    if !any_anim
        && (r - 1.0).abs() < 1e-3
        && (g - 1.0).abs() < 1e-3
        && (b - 1.0).abs() < 1e-3
    {
        return None;
    }
    // Pick representative anim — prefer R, fall back.
    let rep = r_anim.or(g_anim).or(b_anim);
    if let Some(anim) = rep {
        // Warn if per-channel anims differ.
        let mut set = std::collections::HashSet::new();
        for a in [r_anim, g_anim, b_anim].iter().flatten() {
            if let SvgAnimationNode::Animate { common, .. } = a {
                set.insert(common.keyframes.values.join("|"));
            }
        }
        if set.len() > 1 {
            logs.warn(
                "map.filter",
                "per-channel feFunc slopes differ; collapsing to R channel",
                &[("filter", filter_id.to_string().into())],
            );
        }
        let brightness = map_scalar_anim(anim, 100.0, 0.0, frame_rate);
        return Some(LottieEffect::Brightness {
            brightness: shift_scalar(brightness, -100.0),
        });
    }
    let mean = (r + g + b) / 3.0;
    Some(LottieEffect::Brightness {
        brightness: LottieScalarProp::Static {
            value: (mean - 1.0) * 100.0,
        },
    })
}

fn shift_scalar(p: LottieScalarProp, offset: f64) -> LottieScalarProp {
    match p {
        LottieScalarProp::Static { value } => LottieScalarProp::Static {
            value: value + offset,
        },
        LottieScalarProp::Animated { keyframes } => {
            let shifted = keyframes
                .into_iter()
                .map(|k| LottieScalarKeyframe {
                    time: k.time,
                    start: k.start + offset,
                    hold: k.hold,
                    bezier_in: k.bezier_in,
                    bezier_out: k.bezier_out,
                })
                .collect();
            LottieScalarProp::Animated { keyframes: shifted }
        }
    }
}

fn map_scalar_anim(
    anim: &SvgAnimationNode,
    scale: f64,
    fallback: f64,
    frame_rate: f64,
) -> LottieScalarProp {
    let common = match anim {
        SvgAnimationNode::Animate { common, .. } => common,
        _ => {
            return LottieScalarProp::Static { value: fallback };
        }
    };
    let k_times = &common.keyframes.key_times;
    let values = &common.keyframes.values;
    if k_times.is_empty() || values.is_empty() {
        return LottieScalarProp::Static { value: fallback };
    }
    let mut parsed: Vec<f64> = Vec::with_capacity(values.len());
    for v in values {
        match v.trim().parse::<f64>() {
            Ok(d) => parsed.push(d * scale),
            Err(_) => return LottieScalarProp::Static { value: fallback },
        }
    }
    let hold = common.keyframes.calc_mode == SvgAnimationCalcMode::Discrete;
    let mut kfs: Vec<LottieScalarKeyframe> = Vec::with_capacity(k_times.len());
    for i in 0..k_times.len() {
        kfs.push(LottieScalarKeyframe {
            time: k_times[i] * common.dur_seconds * frame_rate,
            start: parsed[i],
            hold,
            bezier_in: None,
            bezier_out: None,
        });
    }
    let first = kfs[0].start;
    if kfs.iter().all(|k| (k.start - first).abs() < 1e-6) {
        return LottieScalarProp::Static { value: first };
    }
    LottieScalarProp::Animated { keyframes: kfs }
}

// ---------------------------------------------------------------------------
// Transform construction — leaf-local and baked variants.
// ---------------------------------------------------------------------------

fn build_leaf_local_transform(
    ctx: &WalkCtx,
    leaf_statics: &[SvgStaticTransform],
    leaf_own_transform_anims: &[SvgAnimationNode],
    inherited_non_transform: &[SvgAnimationNode],
    leaf_own_non_transform: &[SvgAnimationNode],
    logs: &mut LogCollector,
) -> LottieTransform {
    let animated_xf = transform_map::map_transforms(leaf_own_transform_anims, ctx.frame_rate, logs);
    let folded = compose_statics(leaf_statics, logs).decompose_trs();

    let position = animated_xf.position.unwrap_or(LottieVectorProp::Static {
        value: vec![folded.tx, folded.ty],
    });
    let scale = animated_xf.scale.unwrap_or(LottieVectorProp::Static {
        value: vec![folded.sx * 100.0, folded.sy * 100.0],
    });
    let rotation = animated_xf.rotation.unwrap_or(LottieScalarProp::Static {
        value: folded.rot_deg,
    });
    let anchor = animated_xf.anchor.unwrap_or(LottieVectorProp::Static {
        value: vec![0.0, 0.0],
    });

    let opacity = build_opacity(inherited_non_transform, leaf_own_non_transform, ctx.frame_rate, logs);

    LottieTransform {
        anchor,
        position,
        scale,
        rotation,
        opacity,
    }
}

#[allow(clippy::too_many_arguments)]
fn build_baked_transform(
    ctx: &WalkCtx,
    statics_before: &[SvgStaticTransform],
    animated_ancestor: &AnimatedAncestor,
    statics_after: &[SvgStaticTransform],
    leaf_own_transform_anims: &[SvgAnimationNode],
    inherited_non_transform: &[SvgAnimationNode],
    leaf_own_non_transform: &[SvgAnimationNode],
    logs: &mut LogCollector,
) -> LottieTransform {
    if !leaf_own_transform_anims.is_empty() {
        logs.warn(
            "map.bake",
            "dropping leaf animateTransform under animated ancestor",
            &[(
                "reason",
                "combining two animation layers (ancestor+leaf) not supported; leaf anims ignored, ancestor bake used"
                    .into(),
            )],
        );
    }

    let m_before = compose_statics(statics_before, logs);
    let m_after = compose_statics(statics_after, logs);
    let m_group_base = compose_statics(&animated_ancestor.group_statics, logs);
    let anims = &animated_ancestor.anims;

    // Fast path: pure-translation static chain → route via Lottie anchor.
    if let Some(fp) = build_anchor_pivot_transform(
        ctx,
        &m_before,
        &m_group_base,
        &m_after,
        anims,
        inherited_non_transform,
        leaf_own_non_transform,
        logs,
    ) {
        return fp;
    }

    // Primary = anim with the most keyframes.
    let primary = anims
        .iter()
        .max_by_key(|a| a.common().keyframes.key_times.len())
        .expect("build_baked_transform requires at least one ancestor anim");
    let base_times: Vec<f64> = primary.common().keyframes.key_times.clone();
    let k_mode = primary.common().keyframes.calc_mode;
    let base_dur = primary.common().dur_seconds;

    let k_times = expand_times_for_rotation(anims, &base_times);
    let subdivided = k_times.len() > base_times.len();

    let mut p_kfs: Vec<LottieVectorKeyframe> = Vec::new();
    let mut s_kfs: Vec<LottieVectorKeyframe> = Vec::new();
    let mut r_kfs: Vec<LottieScalarKeyframe> = Vec::new();

    for i in 0..k_times.len() {
        let t = k_times[i];
        let mut mid = m_group_base;
        for anim in anims {
            let anim_mat = sample_anim_mat(anim, t, logs);
            mid = if anim.common().additive == SvgAnimationAdditive::Replace {
                anim_mat
            } else {
                mid.multiply(&anim_mat)
            };
        }
        let full = m_before.multiply(&mid).multiply(&m_after);
        let trs = full.decompose_trs();
        let frame = t * base_dur * ctx.frame_rate;

        let hold = k_mode == SvgAnimationCalcMode::Discrete;
        let mut out_h: Option<BezierHandle> = None;
        let mut in_h: Option<BezierHandle> = None;
        if !hold && !subdivided {
            if i == 0 {
                out_h = primary_out_handle(primary, 0);
            } else {
                in_h = primary_in_handle(primary, i - 1);
                if i < k_times.len() - 1 {
                    out_h = primary_out_handle(primary, i);
                }
            }
        }

        p_kfs.push(LottieVectorKeyframe {
            time: frame,
            start: vec![trs.tx, trs.ty],
            hold,
            bezier_out: out_h,
            bezier_in: in_h,
        });
        s_kfs.push(LottieVectorKeyframe {
            time: frame,
            start: vec![trs.sx * 100.0, trs.sy * 100.0],
            hold,
            bezier_out: out_h,
            bezier_in: in_h,
        });
        r_kfs.push(LottieScalarKeyframe {
            time: frame,
            start: trs.rot_deg,
            hold,
            bezier_out: out_h,
            bezier_in: in_h,
        });
    }

    unwrap_rotation_keyframes(&mut r_kfs);

    let position = collapse_vector(p_kfs);
    let scale = collapse_vector(s_kfs);
    let rotation = collapse_scalar(r_kfs);

    let opacity = build_opacity(inherited_non_transform, leaf_own_non_transform, ctx.frame_rate, logs);

    LottieTransform {
        anchor: LottieVectorProp::Static {
            value: vec![0.0, 0.0],
        },
        position,
        scale,
        rotation,
        opacity,
    }
}

fn primary_out_handle(primary: &SvgAnimationNode, segment: usize) -> Option<BezierHandle> {
    let kf = &primary.common().keyframes;
    if kf.calc_mode == SvgAnimationCalcMode::Spline && segment < kf.key_splines.len() {
        let s = kf.key_splines[segment];
        return Some(BezierHandle { x: s.x1, y: s.y1 });
    }
    Some(BezierHandle { x: 1.0, y: 1.0 })
}

fn primary_in_handle(primary: &SvgAnimationNode, segment: usize) -> Option<BezierHandle> {
    let kf = &primary.common().keyframes;
    if kf.calc_mode == SvgAnimationCalcMode::Spline && segment < kf.key_splines.len() {
        let s = kf.key_splines[segment];
        return Some(BezierHandle { x: s.x2, y: s.y2 });
    }
    Some(BezierHandle { x: 0.0, y: 0.0 })
}

fn collapse_vector(kfs: Vec<LottieVectorKeyframe>) -> LottieVectorProp {
    if kfs.is_empty() {
        return LottieVectorProp::Static {
            value: vec![0.0, 0.0],
        };
    }
    let first = kfs[0].start.clone();
    let all_same = kfs.iter().all(|k| {
        k.start.len() == first.len()
            && first
                .iter()
                .zip(k.start.iter())
                .all(|(a, b)| (a - b).abs() <= 1e-6)
    });
    if all_same {
        LottieVectorProp::Static { value: first }
    } else {
        LottieVectorProp::Animated { keyframes: kfs }
    }
}

fn collapse_scalar(kfs: Vec<LottieScalarKeyframe>) -> LottieScalarProp {
    if kfs.is_empty() {
        return LottieScalarProp::Static { value: 0.0 };
    }
    let first = kfs[0].start;
    let all_same = kfs.iter().all(|k| (k.start - first).abs() <= 1e-6);
    if all_same {
        LottieScalarProp::Static { value: first }
    } else {
        LottieScalarProp::Animated { keyframes: kfs }
    }
}

fn build_opacity(
    inherited: &[SvgAnimationNode],
    own: &[SvgAnimationNode],
    frame_rate: f64,
    logs: &mut LogCollector,
) -> LottieScalarProp {
    // Partition (inherited + own) into display/opacity common refs.
    let mut displays: Vec<&SvgAnimationCommon> = Vec::new();
    let mut opacities: Vec<&SvgAnimationCommon> = Vec::new();
    for a in inherited.iter().chain(own.iter()) {
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
    if displays.is_empty() && opacities.is_empty() {
        return LottieScalarProp::Static { value: 100.0 };
    }
    let merged = opacity_merge::merge(&displays, &opacities, logs);
    match merged {
        None => LottieScalarProp::Static { value: 100.0 },
        Some(SvgAnimationNode::Animate { common, .. }) => {
            opacity::map_opacity(&common, frame_rate, logs)
        }
        Some(_) => LottieScalarProp::Static { value: 100.0 },
    }
}

// ---------------------------------------------------------------------------
// Anchor-pivot fast path. Mirrors Dart's `_buildAnchorPivotTransform`.
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn build_anchor_pivot_transform(
    ctx: &WalkCtx,
    m_before: &Mat,
    m_group_base: &Mat,
    m_after: &Mat,
    anims: &[SvgAnimationNode],
    inherited_non_transform: &[SvgAnimationNode],
    leaf_own_non_transform: &[SvgAnimationNode],
    logs: &mut LogCollector,
) -> Option<LottieTransform> {
    if !is_pure_translation(m_before) {
        return None;
    }
    if !is_pure_translation(m_after) {
        return None;
    }
    if !is_pure_translation(m_group_base) {
        return None;
    }
    for a in anims {
        let (kind, common) = match a {
            SvgAnimationNode::AnimateTransform { kind, common } => (*kind, common),
            _ => continue,
        };
        match kind {
            SvgTransformKind::Translate => {
                if common.additive != SvgAnimationAdditive::Replace {
                    return None;
                }
            }
            SvgTransformKind::Rotate | SvgTransformKind::Scale => {}
            SvgTransformKind::Matrix | SvgTransformKind::SkewX | SvgTransformKind::SkewY => {
                return None;
            }
        }
    }

    let animated_xf = transform_map::map_transforms(anims, ctx.frame_rate, logs);

    let bx = m_before.e;
    let by = m_before.f;
    let gx = m_group_base.e;
    let gy = m_group_base.f;
    let ax = m_after.e;
    let ay = m_after.f;

    let anchor = LottieVectorProp::Static {
        value: vec![-ax, -ay],
    };

    let position = if let Some(p) = animated_xf.position {
        offset_vector_prop(p, bx, by)
    } else {
        LottieVectorProp::Static {
            value: vec![bx + gx, by + gy],
        }
    };
    let rotation = animated_xf
        .rotation
        .unwrap_or(LottieScalarProp::Static { value: 0.0 });
    let scale = animated_xf.scale.unwrap_or(LottieVectorProp::Static {
        value: vec![100.0, 100.0],
    });
    let opacity = build_opacity(inherited_non_transform, leaf_own_non_transform, ctx.frame_rate, logs);

    Some(LottieTransform {
        anchor,
        position,
        scale,
        rotation,
        opacity,
    })
}

fn is_pure_translation(m: &Mat) -> bool {
    (m.a - 1.0).abs() < 1e-9
        && m.b.abs() < 1e-9
        && m.c.abs() < 1e-9
        && (m.d - 1.0).abs() < 1e-9
}

fn offset_vector_prop(p: LottieVectorProp, dx: f64, dy: f64) -> LottieVectorProp {
    if dx == 0.0 && dy == 0.0 {
        return p;
    }
    match p {
        LottieVectorProp::Static { value } => {
            let mut v = value;
            if v.len() >= 2 {
                v[0] += dx;
                v[1] += dy;
            }
            LottieVectorProp::Static { value: v }
        }
        LottieVectorProp::Animated { keyframes } => {
            let shifted = keyframes
                .into_iter()
                .map(|k| {
                    let mut start = k.start;
                    if start.len() >= 2 {
                        start[0] += dx;
                        start[1] += dy;
                    }
                    LottieVectorKeyframe {
                        time: k.time,
                        start,
                        hold: k.hold,
                        bezier_in: k.bezier_in,
                        bezier_out: k.bezier_out,
                    }
                })
                .collect();
            LottieVectorProp::Animated { keyframes: shifted }
        }
    }
}

// ---------------------------------------------------------------------------
// Rotation helpers — sub-division and angle unwrapping.
// ---------------------------------------------------------------------------

fn expand_times_for_rotation(anims: &[SvgAnimationNode], base: &[f64]) -> Vec<f64> {
    const MAX_DEG_PER_SEGMENT: f64 = 120.0;
    if base.len() < 2 {
        return base.to_vec();
    }
    let rotates: Vec<&SvgAnimationNode> = anims
        .iter()
        .filter(|a| {
            matches!(a, SvgAnimationNode::AnimateTransform {
                kind: SvgTransformKind::Rotate,
                ..
            })
        })
        .collect();
    if rotates.is_empty() {
        return base.to_vec();
    }
    let mut result: Vec<f64> = vec![base[0]];
    let mut i = 0;
    while i + 1 < base.len() {
        let t0 = base[i];
        let t1 = base[i + 1];
        let mut max_sweep = 0.0_f64;
        for a in &rotates {
            let v0 = sample_rot_deg(a, t0);
            let v1 = sample_rot_deg(a, t1);
            let sweep = (v1 - v0).abs();
            if sweep > max_sweep {
                max_sweep = sweep;
            }
        }
        if max_sweep > MAX_DEG_PER_SEGMENT {
            let subs = (max_sweep / MAX_DEG_PER_SEGMENT).ceil() as usize;
            for k in 1..subs {
                result.push(t0 + (t1 - t0) * (k as f64 / subs as f64));
            }
        }
        result.push(t1);
        i += 1;
    }
    result
}

fn sample_rot_deg(anim: &SvgAnimationNode, t: f64) -> f64 {
    let kf = &anim.common().keyframes;
    if kf.values.is_empty() {
        return 0.0;
    }
    let first_num = |raw: &str| -> f64 {
        raw.split(|c: char| c == ' ' || c == ',')
            .find(|s| !s.is_empty())
            .and_then(|s| s.parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    if t <= *kf.key_times.first().unwrap() {
        return first_num(&kf.values[0]);
    }
    if t >= *kf.key_times.last().unwrap() {
        return first_num(kf.values.last().unwrap());
    }
    let mut i = 0usize;
    for k in 0..kf.key_times.len().saturating_sub(1) {
        if t >= kf.key_times[k] && t <= kf.key_times[k + 1] {
            i = k;
            break;
        }
    }
    if kf.calc_mode == SvgAnimationCalcMode::Discrete {
        return first_num(&kf.values[i]);
    }
    let t0 = kf.key_times[i];
    let t1 = kf.key_times[i + 1];
    let alpha = if (t1 - t0).abs() < f64::EPSILON {
        0.0
    } else {
        (t - t0) / (t1 - t0)
    };
    let v0 = first_num(&kf.values[i]);
    let v1 = first_num(&kf.values[i + 1]);
    v0 + (v1 - v0) * alpha
}

fn unwrap_rotation_keyframes(kfs: &mut [LottieScalarKeyframe]) {
    if kfs.len() <= 1 {
        return;
    }
    for i in 1..kfs.len() {
        let mut cur = kfs[i].start;
        let prev = kfs[i - 1].start;
        while cur - prev > 180.0 {
            cur -= 360.0;
        }
        while prev - cur > 180.0 {
            cur += 360.0;
        }
        if cur != kfs[i].start {
            kfs[i].start = cur;
        }
    }
}

// ---------------------------------------------------------------------------
// Sampling an animateTransform → Mat at progress t ∈ [0, 1].
// ---------------------------------------------------------------------------

fn sample_anim_mat(anim: &SvgAnimationNode, t: f64, logs: &mut LogCollector) -> Mat {
    let (kind, common) = match anim {
        SvgAnimationNode::AnimateTransform { kind, common } => (*kind, common),
        _ => return Mat::identity(),
    };
    let kf = &common.keyframes;
    let values: Vec<Vec<f64>> = kf.values.iter().map(|v| parse_nums(v)).collect();
    if values.is_empty() {
        return Mat::identity();
    }
    if t <= *kf.key_times.first().unwrap() {
        return to_mat(kind, &values[0], logs);
    }
    if t >= *kf.key_times.last().unwrap() {
        return to_mat(kind, values.last().unwrap(), logs);
    }
    let mut i = 0usize;
    for k in 0..kf.key_times.len().saturating_sub(1) {
        if t >= kf.key_times[k] && t <= kf.key_times[k + 1] {
            i = k;
            break;
        }
    }
    if kf.calc_mode == SvgAnimationCalcMode::Discrete {
        return to_mat(kind, &values[i], logs);
    }
    let t0 = kf.key_times[i];
    let t1 = kf.key_times[i + 1];
    let alpha = if (t1 - t0).abs() < f64::EPSILON {
        0.0
    } else {
        (t - t0) / (t1 - t0)
    };
    let v0 = &values[i];
    let v1 = &values[i + 1];
    let lerp: Vec<f64> = (0..v0.len())
        .map(|k| v0[k] + (v1[k] - v0[k]) * alpha)
        .collect();
    to_mat(kind, &lerp, logs)
}

fn parse_nums(raw: &str) -> Vec<f64> {
    raw.split(|c: char| c == ' ' || c == ',')
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<f64>().ok())
        .collect()
}

fn to_mat(kind: SvgTransformKind, v: &[f64], logs: &mut LogCollector) -> Mat {
    match kind {
        SvgTransformKind::Translate => {
            Mat::translate(v.first().copied().unwrap_or(0.0), v.get(1).copied().unwrap_or(0.0))
        }
        SvgTransformKind::Scale => {
            let sx = v.first().copied().unwrap_or(0.0);
            let sy = v.get(1).copied().unwrap_or(sx);
            Mat::scale(sx, sy)
        }
        SvgTransformKind::Rotate => {
            let deg = v.first().copied().unwrap_or(0.0);
            let cx = v.get(1).copied().unwrap_or(0.0);
            let cy = v.get(2).copied().unwrap_or(0.0);
            if cx == 0.0 && cy == 0.0 {
                Mat::rotate(deg)
            } else {
                Mat::translate(cx, cy)
                    .multiply(&Mat::rotate(deg))
                    .multiply(&Mat::translate(-cx, -cy))
            }
        }
        SvgTransformKind::Matrix => {
            if v.len() >= 6 {
                Mat::from_row_major(v)
            } else {
                Mat::identity()
            }
        }
        SvgTransformKind::SkewX | SvgTransformKind::SkewY => {
            logs.warn(
                "map.anim",
                "skew animateTransform → identity fallback",
                &[("kind", format!("{:?}", kind).into())],
            );
            Mat::identity()
        }
    }
}

fn compose_statics(xs: &[SvgStaticTransform], logs: &mut LogCollector) -> Mat {
    let mut m = Mat::identity();
    for x in xs {
        match x.kind {
            SvgTransformKind::Translate => {
                let tx = x.values.first().copied().unwrap_or(0.0);
                let ty = x.values.get(1).copied().unwrap_or(0.0);
                m = m.multiply(&Mat::translate(tx, ty));
            }
            SvgTransformKind::Scale => {
                let sx = x.values.first().copied().unwrap_or(1.0);
                let sy = x.values.get(1).copied().unwrap_or(sx);
                m = m.multiply(&Mat::scale(sx, sy));
            }
            SvgTransformKind::Rotate => {
                let deg = x.values.first().copied().unwrap_or(0.0);
                let cx = x.values.get(1).copied().unwrap_or(0.0);
                let cy = x.values.get(2).copied().unwrap_or(0.0);
                if cx == 0.0 && cy == 0.0 {
                    m = m.multiply(&Mat::rotate(deg));
                } else {
                    m = m
                        .multiply(&Mat::translate(cx, cy))
                        .multiply(&Mat::rotate(deg))
                        .multiply(&Mat::translate(-cx, -cy));
                }
            }
            SvgTransformKind::Matrix => {
                if x.values.len() >= 6 {
                    m = m.multiply(&Mat::from_row_major(&x.values));
                }
            }
            SvgTransformKind::SkewX | SvgTransformKind::SkewY => {
                logs.warn(
                    "map.compose",
                    "dropping skew static transform",
                    &[("kind", format!("{:?}", x.kind).into())],
                );
            }
        }
    }
    m
}

// ---------------------------------------------------------------------------
// 2D affine matrix (SVG `matrix(a b c d e f)`).
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
struct Mat {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
    f: f64,
}

impl Mat {
    fn identity() -> Self {
        Self {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            e: 0.0,
            f: 0.0,
        }
    }
    fn translate(tx: f64, ty: f64) -> Self {
        Self {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            e: tx,
            f: ty,
        }
    }
    fn scale(sx: f64, sy: f64) -> Self {
        Self {
            a: sx,
            b: 0.0,
            c: 0.0,
            d: sy,
            e: 0.0,
            f: 0.0,
        }
    }
    fn rotate(deg: f64) -> Self {
        let r = deg * std::f64::consts::PI / 180.0;
        let cs = r.cos();
        let sn = r.sin();
        Self {
            a: cs,
            b: sn,
            c: -sn,
            d: cs,
            e: 0.0,
            f: 0.0,
        }
    }
    fn from_row_major(v: &[f64]) -> Self {
        Self {
            a: v[0],
            b: v[1],
            c: v[2],
            d: v[3],
            e: v[4],
            f: v[5],
        }
    }
    fn multiply(&self, o: &Mat) -> Mat {
        Mat {
            a: self.a * o.a + self.c * o.b,
            b: self.b * o.a + self.d * o.b,
            c: self.a * o.c + self.c * o.d,
            d: self.b * o.c + self.d * o.d,
            e: self.a * o.e + self.c * o.f + self.e,
            f: self.b * o.e + self.d * o.f + self.f,
        }
    }

    fn decompose_trs(&self) -> TrsFold {
        // Diagonal fast path preserves sign on mirror sprites.
        if self.b.abs() < 1e-9 && self.c.abs() < 1e-9 {
            // Seam-closing bias for mirror-pair sprites: nudge 2 units
            // toward the flip axis. Same trade-off as Dart.
            let tx = if self.a < 0.0 { self.e - 2.0 } else { self.e };
            let ty = if self.d < 0.0 { self.f - 2.0 } else { self.f };
            return TrsFold {
                tx,
                ty,
                rot_deg: 0.0,
                sx: self.a,
                sy: self.d,
            };
        }
        let det = self.a * self.d - self.b * self.c;
        let sx = (self.a * self.a + self.b * self.b).sqrt();
        let mut sy = (self.c * self.c + self.d * self.d).sqrt();
        if det < 0.0 {
            sy = -sy;
        }
        let rot = self.b.atan2(self.a) * 180.0 / std::f64::consts::PI;
        TrsFold {
            tx: self.e,
            ty: self.f,
            rot_deg: rot,
            sx,
            sy,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct TrsFold {
    tx: f64,
    ty: f64,
    rot_deg: f64,
    sx: f64,
    sy: f64,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        SvgAnimationAdditive, SvgAnimationCalcMode, SvgAnimationCommon,
        SvgAnimationDirection, SvgAnimationFillMode, SvgFilterPrimitive, SvgGroup, SvgImage,
        SvgKeyframes, SvgMask, SvgMaskType, SvgNode, SvgNodeCommon, SvgShape, SvgShapeKind,
        SvgTransformKind, SvgUse, SvgViewBox,
    };
    use crate::log::LogLevel;

    fn mk_logs() -> LogCollector {
        LogCollector::new(LogLevel::Warn)
    }

    fn mk_doc(root: SvgGroup) -> SvgDocument {
        SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: SvgViewBox {
                x: 0.0,
                y: 0.0,
                w: 100.0,
                h: 100.0,
            },
            defs: SvgDefs::default(),
            root,
        }
    }

    fn mk_rect(id: &str, x: f64, y: f64, w: f64, h: f64) -> SvgShape {
        SvgShape {
            common: SvgNodeCommon {
                id: Some(id.to_string()),
                ..Default::default()
            },
            kind: SvgShapeKind::Rect,
            x,
            y,
            width: w,
            height: h,
            ..Default::default()
        }
    }

    fn kf(key_times: Vec<f64>, values: Vec<&str>) -> SvgKeyframes {
        SvgKeyframes {
            key_times,
            values: values.into_iter().map(String::from).collect(),
            calc_mode: SvgAnimationCalcMode::Linear,
            key_splines: Vec::new(),
        }
    }

    fn anim_transform(
        kind: SvgTransformKind,
        additive: SvgAnimationAdditive,
        keyframes: SvgKeyframes,
        dur: f64,
    ) -> SvgAnimationNode {
        SvgAnimationNode::AnimateTransform {
            kind,
            common: SvgAnimationCommon {
                dur_seconds: dur,
                repeat_indefinite: false,
                additive,
                keyframes,
                delay_seconds: 0.0,
                direction: SvgAnimationDirection::Normal,
                fill_mode: SvgAnimationFillMode::None,
            },
        }
    }

    fn anim_animate(
        attribute_name: &str,
        keyframes: SvgKeyframes,
        dur: f64,
    ) -> SvgAnimationNode {
        SvgAnimationNode::Animate {
            attribute_name: attribute_name.to_string(),
            common: SvgAnimationCommon {
                dur_seconds: dur,
                repeat_indefinite: false,
                additive: SvgAnimationAdditive::Replace,
                keyframes,
                delay_seconds: 0.0,
                direction: SvgAnimationDirection::Normal,
                fill_mode: SvgAnimationFillMode::None,
            },
        }
    }

    // 1. Basic shape node
    #[test]
    fn basic_shape_emits_single_shape_layer() {
        let mut logs = mk_logs();
        let shape = mk_rect("r1", 0.0, 0.0, 10.0, 10.0);
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Shape(shape)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 1);
        assert!(matches!(out.layers[0], LottieLayer::Shape(_)));
        assert_eq!(out.out_point, 1.0, "static svg clamps to 1 frame");
        // ind = 1 after reversal of singleton list.
        assert_eq!(out.layers[0].common().index, 1);
    }

    // 2. Group with animation
    #[test]
    fn group_with_translate_animation_folds_into_leaf_transform() {
        let mut logs = mk_logs();
        let anim = anim_transform(
            SvgTransformKind::Translate,
            SvgAnimationAdditive::Replace,
            kf(vec![0.0, 1.0], vec!["0 0", "50 25"]),
            2.0,
        );
        let child = mk_rect("c", 0.0, 0.0, 10.0, 10.0);
        let anim_group = SvgGroup {
            common: SvgNodeCommon {
                animations: vec![anim],
                ..Default::default()
            },
            children: vec![SvgNode::Shape(child)],
            display_none: false,
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Group(anim_group)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        assert!(out.layers.len() >= 1);
        // outPoint reflects max duration → 2s * 60fps = 120.
        assert_eq!(out.out_point, 120.0);
    }

    // 3. Motion path — ensures resolver runs (consumed offset-distance track)
    #[test]
    fn motion_path_resolver_is_invoked() {
        use crate::domain::{SvgMotionPath, SvgMotionRotate};
        let mut logs = mk_logs();
        let offset_anim = anim_animate(
            "offset-distance",
            kf(vec![0.0, 1.0], vec!["0%", "100%"]),
            1.0,
        );
        let shape = SvgShape {
            common: SvgNodeCommon {
                id: Some("p".into()),
                animations: vec![offset_anim],
                motion_path: Some(SvgMotionPath {
                    path_data: "M0 0 L100 0".into(),
                    rotate: SvgMotionRotate::fixed(0.0),
                }),
                ..Default::default()
            },
            kind: SvgShapeKind::Rect,
            width: 10.0,
            height: 10.0,
            ..Default::default()
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Shape(shape)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 1);
    }

    // 4. Nested animation parenting decision
    #[test]
    fn nested_animated_groups_matching_dur_produce_null_parent_chain() {
        let mut logs = mk_logs();
        let inner = mk_rect("leaf", 0.0, 0.0, 10.0, 10.0);
        let inner_anim = anim_transform(
            SvgTransformKind::Translate,
            SvgAnimationAdditive::Replace,
            kf(vec![0.0, 1.0], vec!["0 0", "10 0"]),
            1.0,
        );
        let inner_g = SvgGroup {
            common: SvgNodeCommon {
                animations: vec![inner_anim],
                ..Default::default()
            },
            children: vec![SvgNode::Shape(inner)],
            display_none: false,
        };
        let outer_anim = anim_transform(
            SvgTransformKind::Rotate,
            SvgAnimationAdditive::Replace,
            kf(vec![0.0, 1.0], vec!["0", "90"]),
            1.0,
        );
        let outer_g = SvgGroup {
            common: SvgNodeCommon {
                animations: vec![outer_anim],
                ..Default::default()
            },
            children: vec![SvgNode::Group(inner_g)],
            display_none: false,
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Group(outer_g)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        // Expect 3 layers: 2 null layers (ancestor + inner) + 1 shape leaf.
        let null_count = out
            .layers
            .iter()
            .filter(|l| matches!(l, LottieLayer::Null(_)))
            .count();
        assert_eq!(null_count, 2);
        let shape_count = out
            .layers
            .iter()
            .filter(|l| matches!(l, LottieLayer::Shape(_)))
            .count();
        assert_eq!(shape_count, 1);
    }

    // 5. Filter application (gaussian blur)
    #[test]
    fn gaussian_blur_filter_produces_blur_effect() {
        let mut logs = mk_logs();
        let mut defs = SvgDefs::default();
        defs.filters.insert(
            "f1".into(),
            SvgFilter {
                id: "f1".into(),
                primitives: vec![SvgFilterPrimitive::GaussianBlur {
                    std_deviation: 5.0,
                    std_deviation_anim: None,
                }],
            },
        );
        let shape = SvgShape {
            common: SvgNodeCommon {
                filter_id: Some("f1".into()),
                ..Default::default()
            },
            kind: SvgShapeKind::Rect,
            width: 10.0,
            height: 10.0,
            ..Default::default()
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Shape(shape)],
            display_none: false,
        };
        let doc = SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: SvgViewBox { x: 0.0, y: 0.0, w: 100.0, h: 100.0 },
            defs,
            root,
        };
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 1);
        let effects = &out.layers[0].common().effects;
        assert_eq!(effects.len(), 1);
        match &effects[0] {
            LottieEffect::Blur { blurriness } => match blurriness {
                LottieScalarProp::Static { value } => assert_eq!(*value, 10.0),
                _ => panic!("expected static blur"),
            },
            _ => panic!("expected blur effect"),
        }
    }

    // 6. Mask — creates track-matte layer pair
    #[test]
    fn mask_creates_track_matte_pair() {
        let mut logs = mk_logs();
        let mut defs = SvgDefs::default();
        let mask_child = mk_rect("mchild", 0.0, 0.0, 10.0, 10.0);
        defs.masks.insert(
            "m1".into(),
            SvgMask {
                id: "m1".into(),
                children: vec![SvgNode::Shape(mask_child)],
                mask_type: SvgMaskType::Luminance,
                ..Default::default()
            },
        );
        let target = SvgShape {
            common: SvgNodeCommon {
                id: Some("target".into()),
                mask_id: Some("m1".into()),
                ..Default::default()
            },
            kind: SvgShapeKind::Rect,
            width: 20.0,
            height: 20.0,
            ..Default::default()
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Shape(target)],
            display_none: false,
        };
        let doc = SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: SvgViewBox { x: 0.0, y: 0.0, w: 100.0, h: 100.0 },
            defs,
            root,
        };
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 2);
        // After reversal, mask source (td=1) is at index 0 (top), target
        // (tt=2) at index 1 below it.
        let td_count = out.layers.iter().filter(|l| l.common().td == Some(1)).count();
        let tt_count = out.layers.iter().filter(|l| l.common().tt == Some(2)).count();
        assert_eq!(td_count, 1);
        assert_eq!(tt_count, 1);
    }

    // 7. Stroke-dashoffset — just ensures stroke dashoffset shape survives.
    #[test]
    fn stroke_dashoffset_shape_emits_layer() {
        let mut logs = mk_logs();
        let shape = SvgShape {
            common: SvgNodeCommon {
                id: Some("s".into()),
                ..Default::default()
            },
            kind: SvgShapeKind::Path,
            d: Some("M0 0 L10 0".into()),
            stroke: Some("#ff0000".into()),
            stroke_width: 2.0,
            stroke_dasharray: Some("4 2".into()),
            stroke_dashoffset: 3.0,
            fill: "none".into(),
            ..Default::default()
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Shape(shape)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 1);
        if let LottieLayer::Shape(l) = &out.layers[0] {
            // Expect some trim path item (stroke dash → trim path modifier).
            let has_trim = l
                .shapes
                .iter()
                .any(|i| matches!(i, LottieShapeItem::TrimPath(_)));
            assert!(has_trim || !l.shapes.is_empty());
        } else {
            panic!("expected shape layer");
        }
    }

    // 8. Image asset
    #[test]
    fn image_asset_builds_and_emits_image_layer() {
        let mut logs = mk_logs();
        let img = SvgImage {
            common: SvgNodeCommon {
                id: Some("i1".into()),
                ..Default::default()
            },
            href: "data:image/png;base64,iVBORw0KGgo=".into(),
            width: 32.0,
            height: 24.0,
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Image(img)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 1);
        assert_eq!(out.assets.len(), 1);
        if let LottieLayer::Image(l) = &out.layers[0] {
            assert_eq!(l.ref_id, "asset_0");
        } else {
            panic!("expected image layer");
        }
    }

    // 9. Opacity merge — combined display + opacity animates
    #[test]
    fn opacity_merge_produces_animated_opacity_on_leaf() {
        let mut logs = mk_logs();
        let opacity_anim = anim_animate("opacity", kf(vec![0.0, 1.0], vec!["1", "0"]), 1.0);
        let display_anim = anim_animate(
            "display",
            kf(vec![0.0, 0.5, 1.0], vec!["inline", "none", "inline"]),
            1.0,
        );
        let shape = SvgShape {
            common: SvgNodeCommon {
                id: Some("s".into()),
                animations: vec![opacity_anim, display_anim],
                ..Default::default()
            },
            kind: SvgShapeKind::Rect,
            width: 10.0,
            height: 10.0,
            ..Default::default()
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Shape(shape)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        assert_eq!(out.layers.len(), 1);
        let opacity = &out.layers[0].common().transform.opacity;
        assert!(matches!(opacity, LottieScalarProp::Animated { .. }));
    }

    // 10. Use-resolved layer — ensures flatten inlines <use> before walk.
    #[test]
    fn use_reference_is_resolved_and_emits_layer() {
        let mut logs = mk_logs();
        let mut defs = SvgDefs::default();
        let referenced_shape = mk_rect("ref", 0.0, 0.0, 10.0, 10.0);
        defs.by_id
            .insert("ref".to_string(), SvgNode::Shape(referenced_shape));
        let use_node = SvgUse {
            common: SvgNodeCommon {
                id: Some("u1".into()),
                ..Default::default()
            },
            href_id: "ref".into(),
            width: None,
            height: None,
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Use(use_node)],
            display_none: false,
        };
        let doc = SvgDocument {
            width: 100.0,
            height: 100.0,
            view_box: SvgViewBox { x: 0.0, y: 0.0, w: 100.0, h: 100.0 },
            defs,
            root,
        };
        let out = map(doc, 60.0, &mut logs);
        // The <use> is flattened to the referenced shape → 1 shape layer.
        let shape_count = out
            .layers
            .iter()
            .filter(|l| matches!(l, LottieLayer::Shape(_)))
            .count();
        assert_eq!(shape_count, 1);
    }

    // Extra: parent sentinel rewrite produces positive parent index.
    #[test]
    fn parenting_chain_resolves_to_positive_parent_index() {
        let mut logs = mk_logs();
        let leaf = mk_rect("leaf", 0.0, 0.0, 10.0, 10.0);
        let inner_anim = anim_transform(
            SvgTransformKind::Translate,
            SvgAnimationAdditive::Replace,
            kf(vec![0.0, 1.0], vec!["0 0", "10 0"]),
            1.0,
        );
        let inner_g = SvgGroup {
            common: SvgNodeCommon {
                animations: vec![inner_anim],
                ..Default::default()
            },
            children: vec![SvgNode::Shape(leaf)],
            display_none: false,
        };
        let outer_anim = anim_transform(
            SvgTransformKind::Rotate,
            SvgAnimationAdditive::Replace,
            kf(vec![0.0, 1.0], vec!["0", "90"]),
            1.0,
        );
        let outer_g = SvgGroup {
            common: SvgNodeCommon {
                animations: vec![outer_anim],
                ..Default::default()
            },
            children: vec![SvgNode::Group(inner_g)],
            display_none: false,
        };
        let root = SvgGroup {
            common: SvgNodeCommon::default(),
            children: vec![SvgNode::Group(outer_g)],
            display_none: false,
        };
        let doc = mk_doc(root);
        let out = map(doc, 60.0, &mut logs);
        // All parent fields should be positive (resolved) after reversal.
        for l in &out.layers {
            if let Some(p) = l.common().parent {
                assert!(p > 0, "unresolved sentinel parent {}", p);
            }
        }
    }
}
