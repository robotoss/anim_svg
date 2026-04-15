import 'dart:math' as math;

import '../../core/logger.dart';
import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_document.dart';
import '../../domain/entities/svg_transform.dart';
import 'animation_normalizer.dart';
import 'display_mapper.dart';
import 'motion_path_resolver.dart';
import 'nested_animation_classifier.dart';
import 'image_asset_builder.dart';
import 'opacity_mapper.dart';
import 'opacity_merge.dart';
import 'shape_mapper.dart';
import 'transform_mapper.dart';
import 'use_flattener.dart';

class SvgToLottieMapper {
  SvgToLottieMapper({
    this.frameRate = 60,
    UseFlattener? flattener,
    TransformMapper? transforms,
    OpacityMapper? opacity,
    DisplayMapper? display,
    OpacityMerger? opacityMerger,
    ImageAssetBuilder? assets,
    ShapeMapper? shapes,
    AnimationNormalizer? normalizer,
    NestedAnimationClassifier? nestedClassifier,
    MotionPathResolver? motionPathResolver,
    AnimSvgLogger? logger,
  })  : _log = logger ?? SilentLogger(),
        _flattener = flattener ?? const UseFlattener(),
        _normalizer = normalizer ?? AnimationNormalizer(logger: logger),
        _motionPathResolver =
            motionPathResolver ?? MotionPathResolver(logger: logger),
        _nestedClassifier =
            nestedClassifier ?? const NestedAnimationClassifier(),
        _transforms = transforms ??
            TransformMapper(frameRate: frameRate, logger: logger),
        _opacityMerger = opacityMerger ??
            OpacityMerger(
              frameRate: frameRate,
              display: display,
              opacity: opacity,
              logger: logger,
            ),
        _assets = assets ?? ImageAssetBuilder(),
        _shapes = shapes ?? ShapeMapper(frameRate: frameRate);

  final double frameRate;
  final UseFlattener _flattener;
  final AnimationNormalizer _normalizer;
  final MotionPathResolver _motionPathResolver;
  final NestedAnimationClassifier _nestedClassifier;
  final TransformMapper _transforms;
  final OpacityMerger _opacityMerger;
  final ImageAssetBuilder _assets;
  final ShapeMapper _shapes;
  final AnimSvgLogger _log;

  LottieDoc map(SvgDocument rawDoc) {
    // Normalize CSS-only options (direction/delay/fill-mode) into plain
    // forward keyframe tracks, then flatten <use> references. Order
    // matters: normalizer rebuilds nodes by type, so running it before
    // flatten keeps defs entries with their animations intact when the
    // flattener inlines them.
    final normalizedDoc = _normalizer.normalize(rawDoc);
    // Resolve CSS Motion Path (`offset-path` + `offset-distance`) into
    // explicit translate/rotate animate-transform tracks before the <use>
    // flattener runs. The resolver needs `SvgNode.motionPath`, which the
    // flattener does not preserve when inlining a referenced symbol.
    final resolvedDoc = _motionPathResolver.resolve(normalizedDoc);
    final gradients = resolvedDoc.defs.gradients;
    final filters = resolvedDoc.defs.filters;
    final masks = resolvedDoc.defs.masks;
    final doc =
        _log.time('map.flatten', () => _flattener.flatten(resolvedDoc));
    _log.debug('map', 'flattened',
        fields: {'root_children': doc.root.children.length});
    final assets = <LottieAsset>[];
    final layers = <LottieLayer>[];
    final maxDurSec = _FoldState();

    _walk(
      node: doc.root,
      staticsBefore: const [],
      animatedAncestor: null,
      staticsAfter: const [],
      inheritedNonTransform: const [],
      inheritedFilterId: null,
      layerName: 'root',
      parentLottieIdx: null,
      assets: assets,
      layers: layers,
      maxDurSec: maxDurSec,
      gradients: gradients,
      filters: filters,
      masks: masks,
      inMaskSource: false,
    );

    // Lottie requires op > ip. For SVGs without any <animate*> tags (pure
    // static images or CSS-only animations we don't parse) maxDur==0 gives
    // op==ip==0 and thorvg degrades. Clamp to 1 frame minimum.
    final rawOut = (maxDurSec.value * frameRate).ceilToDouble();
    final outPointFrames = rawOut > 0 ? rawOut : 1.0;
    // Lottie layers are drawn bottom-first — reverse to match SVG draw order
    // (first child rendered first = bottom-most in Lottie). Parent refs
    // recorded during walk are walk-order indices (encoded as negative
    // sentinels); resolve them against final Lottie `ind`s here so the
    // emitted JSON references the real layers.
    final total = layers.length;
    final reordered = layers.reversed
        .toList(growable: false)
        .asMap()
        .entries
        .map((e) => _withIndex(e.value, e.key))
        .toList();

    final resolved = reordered.map((l) {
      final p = l.parent;
      if (p == null || p >= 0) return l;
      final walkIdx = -p - 1; // unwrap sentinel
      // reverse mapping: walkIdx i → reordered position (total-1-i) → ind i+1... wait
      // After reversal: walk position i is at reordered index total-1-i, ind=total-i.
      final finalInd = total - walkIdx;
      return _withParent(l, finalInd);
    }).toList();

    final withOutPoints = resolved
        .map((l) => _withOutPoint(l, outPointFrames))
        .toList();

    return LottieDoc(
      frameRate: frameRate,
      inPoint: 0,
      outPoint: outPointFrames,
      width: doc.width,
      height: doc.height,
      assets: assets,
      layers: withOutPoints,
    );
  }

  LottieLayer _withIndex(LottieLayer l, int i) {
    switch (l) {
      case LottieImageLayer():
        return LottieImageLayer(
          index: i + 1,
          name: l.name,
          refId: l.refId,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          width: l.width,
          height: l.height,
          effects: l.effects,
          parent: l.parent,
          td: l.td,
          tt: l.tt,
        );
      case LottieShapeLayer():
        return LottieShapeLayer(
          index: i + 1,
          name: l.name,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          shapes: l.shapes,
          effects: l.effects,
          parent: l.parent,
          td: l.td,
          tt: l.tt,
        );
      case LottieNullLayer():
        return LottieNullLayer(
          index: i + 1,
          name: l.name,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          parent: l.parent,
          td: l.td,
          tt: l.tt,
        );
    }
  }

  LottieLayer _withOutPoint(LottieLayer l, double outPoint) {
    switch (l) {
      case LottieImageLayer():
        return LottieImageLayer(
          index: l.index,
          name: l.name,
          refId: l.refId,
          transform: l.transform,
          inPoint: 0,
          outPoint: outPoint,
          width: l.width,
          height: l.height,
          effects: l.effects,
          parent: l.parent,
          td: l.td,
          tt: l.tt,
        );
      case LottieShapeLayer():
        return LottieShapeLayer(
          index: l.index,
          name: l.name,
          transform: l.transform,
          inPoint: 0,
          outPoint: outPoint,
          shapes: l.shapes,
          effects: l.effects,
          parent: l.parent,
          td: l.td,
          tt: l.tt,
        );
      case LottieNullLayer():
        return LottieNullLayer(
          index: l.index,
          name: l.name,
          transform: l.transform,
          inPoint: 0,
          outPoint: outPoint,
          parent: l.parent,
          td: l.td,
          tt: l.tt,
        );
    }
  }

  LottieLayer _withTrackMatte(LottieLayer l, {int? td, int? tt}) {
    switch (l) {
      case LottieImageLayer():
        return LottieImageLayer(
          index: l.index,
          name: l.name,
          refId: l.refId,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          width: l.width,
          height: l.height,
          effects: l.effects,
          parent: l.parent,
          td: td ?? l.td,
          tt: tt ?? l.tt,
        );
      case LottieShapeLayer():
        return LottieShapeLayer(
          index: l.index,
          name: l.name,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          shapes: l.shapes,
          effects: l.effects,
          parent: l.parent,
          td: td ?? l.td,
          tt: tt ?? l.tt,
        );
      case LottieNullLayer():
        return LottieNullLayer(
          index: l.index,
          name: l.name,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          parent: l.parent,
          td: td ?? l.td,
          tt: tt ?? l.tt,
        );
    }
  }

  void _walk({
    required SvgNode node,
    required List<SvgStaticTransform> staticsBefore,
    required _AnimatedAncestor? animatedAncestor,
    required List<SvgStaticTransform> staticsAfter,
    required List<SvgAnimationNode> inheritedNonTransform,
    required String? inheritedFilterId,
    required String layerName,
    required int? parentLottieIdx,
    required List<LottieAsset> assets,
    required List<LottieLayer> layers,
    required _FoldState maxDurSec,
    required Map<String, SvgGradient> gradients,
    required Map<String, SvgFilter> filters,
    required Map<String, SvgMask> masks,
    required bool inMaskSource,
    SvgMask? pendingMask,
  }) {
    // Resolve an effective mask for this subtree. Non-mask-source nodes that
    // carry `mask="url(#id)"` install themselves as the pendingMask, which
    // propagates to descendant LEAF emissions (SvgShape/SvgImage). Each leaf
    // then appends a fresh mask-source-layer set immediately after itself
    // and stamps `tt` on itself, producing correctly paired Lottie track
    // mattes (source immediately above target after layer reversal).
    SvgMask? effectiveMask = pendingMask;
    if (!inMaskSource && node.maskId != null) {
      final m = masks[node.maskId!];
      if (m == null) {
        _log.warn('map.mask', 'mask not found in defs; rendering unmasked',
            fields: {'id': node.maskId!});
      } else if (m.children.isEmpty) {
        _log.warn('map.mask', 'mask has no renderable children; skipping',
            fields: {'id': m.id});
      } else {
        effectiveMask = m;
      }
    }
    switch (node) {
      case SvgGroup():
        if (node.displayNone && !_hasDisplayAnimation(node.animations)) {
          return;
        }
        _trackMaxDur(node.animations, maxDurSec);
        if (animatedAncestor != null) {
          _trackMaxDur(animatedAncestor.anims, maxDurSec);
        }

        final ownTransformAnims =
            node.animations.whereType<SvgAnimateTransform>().toList();
        final ownNonTransformAnims = node.animations
            .where((a) => a is! SvgAnimateTransform)
            .toList();

        _AnimatedAncestor? nextAncestor = animatedAncestor;
        List<SvgStaticTransform> nextBefore = staticsBefore;
        List<SvgStaticTransform> nextAfter = staticsAfter;
        int? nextParentLottieIdx = parentLottieIdx;

        if (ownTransformAnims.isNotEmpty) {
          if (parentLottieIdx != null) {
            // Already inside a parenting chain — extend it: emit this group
            // as another null-layer and update the parent ref for descendants.
            final idx = _emitNullLayerForGroup(
              node: node,
              ownTransformAnims: ownTransformAnims,
              parentSentinelIdx: parentLottieIdx,
              layers: layers,
            );
            nextParentLottieIdx = -idx - 1; // sentinel
            nextAncestor = null;
            nextBefore = const [];
            nextAfter = const [];
          } else if (animatedAncestor != null) {
            // Two-or-more-deep animated chain. Try parenting; fall back to
            // the old WARN+drop if durations don't line up.
            final chain = [
              ChainEntry(
                durSeconds: animatedAncestor.anims.first.durSeconds,
                repeatIndefinite:
                    animatedAncestor.anims.first.repeatIndefinite,
                transformAnims: animatedAncestor.anims,
              ),
              ChainEntry(
                durSeconds: ownTransformAnims.first.durSeconds,
                repeatIndefinite: ownTransformAnims.first.repeatIndefinite,
                transformAnims: ownTransformAnims,
              ),
            ];
            if (_nestedClassifier.canChainParent(chain)) {
              // Materialise the ancestor + current as null-layers and
              // promote descendants to parent-mode.
              final ancestorIdx = _emitNullLayerFor(
                name: 'anim_g_${layers.length}',
                statics: animatedAncestor.groupStatics,
                anims: animatedAncestor.anims,
                parentSentinelIdx: null,
                layers: layers,
              );
              final curIdx = _emitNullLayerForGroup(
                node: node,
                ownTransformAnims: ownTransformAnims,
                parentSentinelIdx: -ancestorIdx - 1,
                layers: layers,
              );
              nextParentLottieIdx = -curIdx - 1;
              nextAncestor = null;
              nextBefore = const [];
              nextAfter = const [];
            } else {
              _log.warn(
                  'map.walk',
                  'nested animated groups with mismatched dur; '
                      'dropping inner anims',
                  fields: {
                    'group': node.id ?? '(anon)',
                    'outer_dur':
                        animatedAncestor.anims.first.durSeconds,
                    'inner_dur': ownTransformAnims.first.durSeconds,
                  });
              nextBefore = staticsBefore;
              nextAfter = [...staticsAfter, ...node.staticTransforms];
            }
          } else {
            nextAncestor = _AnimatedAncestor(
              groupStatics: node.staticTransforms,
              anims: ownTransformAnims,
            );
            nextAfter = const [];
          }
        } else {
          if (animatedAncestor == null && parentLottieIdx == null) {
            nextBefore = [...staticsBefore, ...node.staticTransforms];
          } else if (parentLottieIdx != null) {
            // Statics below a parenting chain bake into the next leaf's
            // own transform (they're not animated so no chain break).
            nextBefore = [...staticsBefore, ...node.staticTransforms];
          } else {
            nextAfter = [...staticsAfter, ...node.staticTransforms];
          }
        }

        final nextInherited = ownNonTransformAnims.isEmpty
            ? inheritedNonTransform
            : [...inheritedNonTransform, ...ownNonTransformAnims];

        final nextFilterId = node.filterId ?? inheritedFilterId;

        for (final child in node.children) {
          _walk(
            node: child,
            staticsBefore: nextBefore,
            animatedAncestor: nextAncestor,
            staticsAfter: nextAfter,
            inheritedNonTransform: nextInherited,
            inheritedFilterId: nextFilterId,
            layerName: node.id ?? layerName,
            parentLottieIdx: nextParentLottieIdx,
            assets: assets,
            layers: layers,
            maxDurSec: maxDurSec,
            gradients: gradients,
            filters: filters,
            masks: masks,
            inMaskSource: inMaskSource,
            pendingMask: effectiveMask,
          );
        }
      case SvgImage():
        _trackMaxDur(node.animations, maxDurSec);
        if (animatedAncestor != null) {
          _trackMaxDur(animatedAncestor.anims, maxDurSec);
        }
        final assetId = 'asset_${assets.length}';
        final LottieAsset asset;
        try {
          asset = _assets.build(node, assetId: assetId);
        } catch (e) {
          _log.warn('map.image', 'asset build failed; skipping image',
              fields: {'id': node.id ?? '', 'error': e.toString()});
          break;
        }
        assets.add(asset);
        _log.trace('map.image', 'added asset', fields: {
          'id': assetId,
          'w': node.width,
          'h': node.height,
          'href_preview': node.href.length > 48
              ? '${node.href.substring(0, 48)}...'
              : node.href,
        });
        final imgEffects = _resolveEffects(
          node.filterId ?? inheritedFilterId,
          filters,
        );
        final imgLayer = _buildLayer(
          node: node,
          staticsBefore: staticsBefore,
          animatedAncestor: animatedAncestor,
          staticsAfter: staticsAfter,
          inheritedNonTransform: inheritedNonTransform,
          assetId: assetId,
          name: node.id ?? layerName,
          effects: imgEffects,
          parentSentinelIdx: parentLottieIdx,
        );
        _emitLeafWithMask(
          leaf: imgLayer,
          effectiveMask: effectiveMask,
          inMaskSource: inMaskSource,
          layers: layers,
          staticsBefore: staticsBefore,
          animatedAncestor: animatedAncestor,
          staticsAfter: staticsAfter,
          inheritedNonTransform: inheritedNonTransform,
          inheritedFilterId: inheritedFilterId,
          parentLottieIdx: parentLottieIdx,
          assets: assets,
          maxDurSec: maxDurSec,
          gradients: gradients,
          filters: filters,
          masks: masks,
        );
      case SvgUse():
        _log.warn('map.walk', 'skipping unflattened <use>',
            fields: {'hrefId': node.hrefId, 'id': node.id ?? ''});
      case SvgShape():
        _trackMaxDur(node.animations, maxDurSec);
        if (animatedAncestor != null) {
          _trackMaxDur(animatedAncestor.anims, maxDurSec);
        }
        final shapeItems =
            _shapes.map(node, gradients: gradients, logger: _log);
        if (shapeItems.isEmpty) {
          _log.debug('map.shape', 'shape emitted no items; skipping layer',
              fields: {'id': node.id ?? '', 'kind': node.kind.name});
          break;
        }
        final shapeEffects = _resolveEffects(
          node.filterId ?? inheritedFilterId,
          filters,
        );
        final shapeLayer = _buildShapeLayer(
          node: node,
          staticsBefore: staticsBefore,
          animatedAncestor: animatedAncestor,
          staticsAfter: staticsAfter,
          inheritedNonTransform: inheritedNonTransform,
          shapeItems: shapeItems,
          name: node.id ?? layerName,
          effects: shapeEffects,
          parentSentinelIdx: parentLottieIdx,
        );
        _emitLeafWithMask(
          leaf: shapeLayer,
          effectiveMask: effectiveMask,
          inMaskSource: inMaskSource,
          layers: layers,
          staticsBefore: staticsBefore,
          animatedAncestor: animatedAncestor,
          staticsAfter: staticsAfter,
          inheritedNonTransform: inheritedNonTransform,
          inheritedFilterId: inheritedFilterId,
          parentLottieIdx: parentLottieIdx,
          assets: assets,
          maxDurSec: maxDurSec,
          gradients: gradients,
          filters: filters,
          masks: masks,
        );
    }
  }

  /// Append a leaf layer and, if a track-matte mask applies, emit the mask
  /// source layers immediately after (so after the final list reversal the
  /// source sits ABOVE the target — Lottie's track-matte pairing rule).
  ///
  /// When `inMaskSource` is true the leaf itself is a mask source and
  /// gets `td:1`; nested masks inside a mask source are ignored (single
  /// level of indirection to avoid cycles).
  void _emitLeafWithMask({
    required LottieLayer leaf,
    required SvgMask? effectiveMask,
    required bool inMaskSource,
    required List<LottieLayer> layers,
    required List<SvgStaticTransform> staticsBefore,
    required _AnimatedAncestor? animatedAncestor,
    required List<SvgStaticTransform> staticsAfter,
    required List<SvgAnimationNode> inheritedNonTransform,
    required String? inheritedFilterId,
    required int? parentLottieIdx,
    required List<LottieAsset> assets,
    required _FoldState maxDurSec,
    required Map<String, SvgGradient> gradients,
    required Map<String, SvgFilter> filters,
    required Map<String, SvgMask> masks,
  }) {
    if (inMaskSource) {
      // This leaf IS a mask source — stamp td:1 and emit. Its own maskId
      // (if any) is ignored by the top of _walk to avoid recursion.
      layers.add(_withTrackMatte(leaf, td: 1));
      return;
    }
    if (effectiveMask == null) {
      layers.add(leaf);
      return;
    }
    // Emit the target first with tt stamped (2 = luma, 1 = alpha).
    final tt = effectiveMask.type == SvgMaskType.luminance ? 2 : 1;
    layers.add(_withTrackMatte(leaf, tt: tt));
    // Then emit a fresh copy of the mask source(s) immediately after. In
    // the final reversed layer list this places sources above the target,
    // which is exactly the track-matte pairing Lottie expects.
    for (final child in effectiveMask.children) {
      _walk(
        node: child,
        staticsBefore: staticsBefore,
        animatedAncestor: animatedAncestor,
        staticsAfter: staticsAfter,
        inheritedNonTransform: inheritedNonTransform,
        inheritedFilterId: inheritedFilterId,
        layerName: 'mask_${effectiveMask.id}',
        parentLottieIdx: parentLottieIdx,
        assets: assets,
        layers: layers,
        maxDurSec: maxDurSec,
        gradients: gradients,
        filters: filters,
        masks: masks,
        inMaskSource: true,
        pendingMask: null,
      );
    }
  }

  bool _hasDisplayAnimation(List<SvgAnimationNode> anims) {
    for (final a in anims) {
      if (a is SvgAnimate && a.attributeName == 'display') return true;
    }
    return false;
  }

  void _trackMaxDur(List<SvgAnimationNode> anims, _FoldState state) {
    for (final a in anims) {
      if (a.durSeconds > state.value) state.value = a.durSeconds;
    }
  }

  LottieLayer _buildLayer({
    required SvgImage node,
    required List<SvgStaticTransform> staticsBefore,
    required _AnimatedAncestor? animatedAncestor,
    required List<SvgStaticTransform> staticsAfter,
    required List<SvgAnimationNode> inheritedNonTransform,
    required String assetId,
    required String name,
    List<LottieEffect> effects = const [],
    int? parentSentinelIdx,
  }) {
    final leafOwnTransformAnims =
        node.animations.whereType<SvgAnimateTransform>().toList();

    final LottieTransform transform;
    if (animatedAncestor == null) {
      transform = _buildLeafLocalTransform(
        leafStatics: [...staticsBefore, ...node.staticTransforms],
        leafOwnTransformAnims: leafOwnTransformAnims,
        inheritedNonTransform: inheritedNonTransform,
        leafOwnNonTransform: node.animations
            .where((a) => a is! SvgAnimateTransform)
            .toList(),
      );
    } else {
      transform = _buildBakedTransform(
        staticsBefore: staticsBefore,
        animatedAncestor: animatedAncestor,
        staticsAfter: [...staticsAfter, ...node.staticTransforms],
        leafOwnTransformAnims: leafOwnTransformAnims,
        inheritedNonTransform: inheritedNonTransform,
        leafOwnNonTransform: node.animations
            .where((a) => a is! SvgAnimateTransform)
            .toList(),
      );
    }

    return LottieImageLayer(
      index: 0,
      name: name,
      refId: assetId,
      inPoint: 0,
      outPoint: 0,
      width: node.width,
      height: node.height,
      transform: transform,
      effects: effects,
      parent: parentSentinelIdx,
    );
  }

  LottieLayer _buildShapeLayer({
    required SvgShape node,
    required List<SvgStaticTransform> staticsBefore,
    required _AnimatedAncestor? animatedAncestor,
    required List<SvgStaticTransform> staticsAfter,
    required List<SvgAnimationNode> inheritedNonTransform,
    required List<LottieShapeItem> shapeItems,
    required String name,
    List<LottieEffect> effects = const [],
    int? parentSentinelIdx,
  }) {
    final leafOwnTransformAnims =
        node.animations.whereType<SvgAnimateTransform>().toList();
    final leafOwnNonTransform =
        node.animations.where((a) => a is! SvgAnimateTransform).toList();

    final LottieTransform transform;
    if (animatedAncestor == null) {
      transform = _buildLeafLocalTransform(
        leafStatics: [...staticsBefore, ...node.staticTransforms],
        leafOwnTransformAnims: leafOwnTransformAnims,
        inheritedNonTransform: inheritedNonTransform,
        leafOwnNonTransform: leafOwnNonTransform,
      );
    } else {
      transform = _buildBakedTransform(
        staticsBefore: staticsBefore,
        animatedAncestor: animatedAncestor,
        staticsAfter: [...staticsAfter, ...node.staticTransforms],
        leafOwnTransformAnims: leafOwnTransformAnims,
        inheritedNonTransform: inheritedNonTransform,
        leafOwnNonTransform: leafOwnNonTransform,
      );
    }

    return LottieShapeLayer(
      index: 0,
      name: name,
      transform: transform,
      inPoint: 0,
      outPoint: 0,
      shapes: shapeItems,
      effects: effects,
      parent: parentSentinelIdx,
    );
  }

  /// Emits a null-layer capturing `ownTransformAnims` applied to a group's
  /// own `staticTransforms`. Returns the walk-order index (position in
  /// `layers`), which callers encode as a sentinel `-idx - 1` when passing
  /// down as a `parent` reference. `_withParent` + the post-walk
  /// resolution pass in `map()` rewrites these sentinels into final
  /// Lottie `ind`s once layers are reversed and numbered.
  int _emitNullLayerForGroup({
    required SvgGroup node,
    required List<SvgAnimateTransform> ownTransformAnims,
    required int? parentSentinelIdx,
    required List<LottieLayer> layers,
  }) {
    return _emitNullLayerFor(
      name: node.id ?? 'anim_g_${layers.length}',
      statics: node.staticTransforms,
      anims: ownTransformAnims,
      parentSentinelIdx: parentSentinelIdx,
      layers: layers,
    );
  }

  int _emitNullLayerFor({
    required String name,
    required List<SvgStaticTransform> statics,
    required List<SvgAnimateTransform> anims,
    required int? parentSentinelIdx,
    required List<LottieLayer> layers,
  }) {
    final transform = _buildLeafLocalTransform(
      leafStatics: statics,
      leafOwnTransformAnims: anims,
      inheritedNonTransform: const [],
      leafOwnNonTransform: const [],
    );
    final idx = layers.length;
    layers.add(LottieNullLayer(
      index: 0,
      name: name,
      transform: transform,
      inPoint: 0,
      outPoint: 0,
      parent: parentSentinelIdx,
    ));
    return idx;
  }

  LottieLayer _withParent(LottieLayer l, int parentInd) {
    switch (l) {
      case LottieImageLayer():
        return LottieImageLayer(
          index: l.index,
          name: l.name,
          refId: l.refId,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          width: l.width,
          height: l.height,
          effects: l.effects,
          parent: parentInd,
          td: l.td,
          tt: l.tt,
        );
      case LottieShapeLayer():
        return LottieShapeLayer(
          index: l.index,
          name: l.name,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          shapes: l.shapes,
          effects: l.effects,
          parent: parentInd,
          td: l.td,
          tt: l.tt,
        );
      case LottieNullLayer():
        return LottieNullLayer(
          index: l.index,
          name: l.name,
          transform: l.transform,
          inPoint: l.inPoint,
          outPoint: l.outPoint,
          parent: parentInd,
          td: l.td,
          tt: l.tt,
        );
    }
  }

  List<LottieEffect> _resolveEffects(
    String? filterId,
    Map<String, SvgFilter> filters,
  ) {
    if (filterId == null) return const [];
    final filter = filters[filterId];
    if (filter == null) {
      _log.warn('map.filter', 'filter id not found in defs; skipping effects',
          fields: {'id': filterId});
      return const [];
    }
    final effects = <LottieEffect>[];
    for (final p in filter.primitives) {
      switch (p) {
        case SvgFilterGaussianBlur():
          // Lottie blur radius is roughly 2× SVG stdDeviation (SVG's stdDev
          // describes a Gaussian kernel; Lottie's `Blurriness` is a pixel
          // radius that empirically lines up at ~2× the SVG value).
          final anim = p.stdDeviationAnim;
          LottieScalarProp blur;
          if (anim != null) {
            blur = _mapScalarAnim(anim, scale: 2.0, fallback: p.stdDeviation * 2);
          } else {
            blur = LottieScalarStatic(p.stdDeviation * 2);
          }
          effects.add(LottieBlurEffect(blurriness: blur));
        case SvgFilterColorMatrix():
          if (p.kind == SvgColorMatrixKind.saturate) {
            // SVG saturate `s` maps to AE Master Saturation `(s - 1) * 100`.
            // s=1 → 0 neutral, s=2 → +100 full boost, s=0 → -100 greyscale.
            // Lottie has no per-channel color-matrix primitive; Hue/Saturation
            // is the nearest semantic match and is rendered by thorvg.
            final anim = p.valuesAnim;
            LottieScalarProp sat;
            if (anim != null) {
              sat = _shiftScalar(
                _mapScalarAnim(anim, scale: 100.0, fallback: 0),
                -100,
              );
            } else {
              sat = LottieScalarStatic((p.values - 1) * 100);
            }
            effects.add(LottieHueSaturationEffect(masterSaturation: sat));
          } else {
            _log.warn('map.filter',
                'feColorMatrix kind not supported in Lottie; skipping',
                fields: {'kind': p.kind.name, 'filter': filterId});
          }
        case SvgFilterComponentTransfer():
          final eff = _buildBrightnessEffect(p, filterId);
          if (eff != null) effects.add(eff);
      }
    }
    return effects;
  }

  /// Pragmatic `feComponentTransfer` → Lottie Brightness&Contrast mapping.
  ///
  /// - If all three channels carry the same animated slope (within
  ///   tolerance), we map one of them to `LottieBrightnessEffect` with the
  ///   animation scaled by 100× (so slope 1 → 0, slope 2 → 100).
  /// - If only a subset is animated or the three animations differ, we
  ///   average the static slopes and WARN; downstream renderers (thorvg)
  ///   don't support per-channel curves anyway.
  /// - If everything is at identity (slope 1, no animation), nothing is
  ///   emitted.
  LottieEffect? _buildBrightnessEffect(
    SvgFilterComponentTransfer p,
    String filterId,
  ) {
    final r = p.slopeR ?? 1.0;
    final g = p.slopeG ?? 1.0;
    final b = p.slopeB ?? 1.0;
    final rAnim = p.slopeRAnim;
    final gAnim = p.slopeGAnim;
    final bAnim = p.slopeBAnim;
    final anyAnim = rAnim != null || gAnim != null || bAnim != null;
    if (!anyAnim &&
        (r - 1).abs() < 1e-3 &&
        (g - 1).abs() < 1e-3 &&
        (b - 1).abs() < 1e-3) {
      return null;
    }
    // Pick one representative animation. Prefer R, fall back to the others.
    final repAnim = rAnim ?? gAnim ?? bAnim;
    if (repAnim != null) {
      final differing = [rAnim, gAnim, bAnim]
          .whereType<SvgAnimate>()
          .map((a) => a.keyframes.values.join('|'))
          .toSet();
      if (differing.length > 1) {
        _log.warn('map.filter',
            'per-channel feFunc slopes differ; collapsing to R channel',
            fields: {'filter': filterId});
      }
      final brightness = _mapScalarAnim(
        repAnim,
        scale: 100.0,
        fallback: 0,
      );
      return LottieBrightnessEffect(
        brightness: _shiftScalar(brightness, -100),
      );
    }
    final mean = (r + g + b) / 3.0;
    return LottieBrightnessEffect(
      brightness: LottieScalarStatic((mean - 1) * 100),
    );
  }

  /// Subtracts `offset` from a scalar property (static or animated) so the
  /// brightness channel centers on 0 when the source slope is 1. Keeps
  /// animated keyframes structurally identical.
  LottieScalarProp _shiftScalar(LottieScalarProp p, double offset) {
    switch (p) {
      case LottieScalarStatic(value: final v):
        return LottieScalarStatic(v + offset);
      case LottieScalarAnimated(keyframes: final kfs):
        return LottieScalarAnimated([
          for (final k in kfs)
            LottieScalarKeyframe(
              time: k.time,
              start: k.start + offset,
              hold: k.hold,
              bezierIn: k.bezierIn,
              bezierOut: k.bezierOut,
            ),
        ]);
    }
  }

  LottieScalarProp _mapScalarAnim(
    SvgAnimate anim, {
    required double scale,
    required double fallback,
  }) {
    final kTimes = anim.keyframes.keyTimes;
    final values = anim.keyframes.values;
    if (kTimes.isEmpty || values.isEmpty) {
      return LottieScalarStatic(fallback);
    }
    final parsed = <double>[];
    for (final v in values) {
      final d = double.tryParse(v.trim());
      if (d == null) return LottieScalarStatic(fallback);
      parsed.add(d * scale);
    }
    final hold = anim.keyframes.calcMode == SvgAnimationCalcMode.discrete;
    final kfs = <LottieScalarKeyframe>[
      for (var i = 0; i < kTimes.length; i++)
        LottieScalarKeyframe(
          time: kTimes[i] * anim.durSeconds * frameRate,
          start: parsed[i],
          hold: hold,
        ),
    ];
    final first = kfs.first.start;
    if (kfs.every((k) => (k.start - first).abs() < 1e-6)) {
      return LottieScalarStatic(first);
    }
    return LottieScalarAnimated(kfs);
  }

  LottieTransform _buildLeafLocalTransform({
    required List<SvgStaticTransform> leafStatics,
    required List<SvgAnimateTransform> leafOwnTransformAnims,
    required List<SvgAnimationNode> inheritedNonTransform,
    required List<SvgAnimationNode> leafOwnNonTransform,
  }) {
    final animatedXf = _transforms.map(animations: leafOwnTransformAnims);
    final folded = _composeStatics(leafStatics).decomposeTRS();

    final position = animatedXf.position ??
        LottieVectorStatic([folded.tx, folded.ty]);
    final scale = animatedXf.scale ??
        LottieVectorStatic([folded.sx * 100, folded.sy * 100]);
    final rotation =
        animatedXf.rotation ?? LottieScalarStatic(folded.rotDeg);
    final anchor = animatedXf.anchor ?? const LottieVectorStatic([0, 0]);

    final opacity = _buildOpacity(inheritedNonTransform, leafOwnNonTransform);

    return LottieTransform(
      anchor: anchor,
      position: position,
      scale: scale,
      rotation: rotation,
      opacity: opacity,
    );
  }

  LottieTransform _buildBakedTransform({
    required List<SvgStaticTransform> staticsBefore,
    required _AnimatedAncestor animatedAncestor,
    required List<SvgStaticTransform> staticsAfter,
    required List<SvgAnimateTransform> leafOwnTransformAnims,
    required List<SvgAnimationNode> inheritedNonTransform,
    required List<SvgAnimationNode> leafOwnNonTransform,
  }) {
    if (leafOwnTransformAnims.isNotEmpty) {
      _log.warn('map.bake', 'dropping leaf animateTransform under animated ancestor',
          fields: {
            'reason': 'combining two animation layers (ancestor+leaf) not supported; '
                'leaf anims ignored, ancestor bake used',
          });
    }

    final mBefore = _composeStatics(staticsBefore);
    final mAfter = _composeStatics(staticsAfter);
    final mGroupBase = _composeStatics(animatedAncestor.groupStatics);
    final anims = animatedAncestor.anims;

    // Fast path — whenever the chain around the animation is pure translation,
    // the animated rotation/scale can be routed through Lottie's native
    // anchor/position/rotation/scale channels instead of baking a composed
    // matrix into a position-trajectory. Baking a chain like
    // `T(p)·R(θ)·T(-p)` flattens correctly but forces the *layer origin* to
    // trace a circle around the pivot even though the visual result should be
    // stationary-plus-rotation. Using Lottie's anchor keeps the rotation pivot
    // where it belongs so the icon spins in place. Falls back to general
    // matrix bake for chains that involve non-translation statics (rotate,
    // scale, skew, matrix) or unusual additive patterns.
    final fastPath = _buildAnchorPivotTransform(
      mBefore: mBefore,
      mGroupBase: mGroupBase,
      mAfter: mAfter,
      anims: anims,
      inheritedNonTransform: inheritedNonTransform,
      leafOwnNonTransform: leafOwnNonTransform,
    );
    if (fastPath != null) return fastPath;

    // Primary = the anim with the most keyframes. Output sample points and
    // bezier handles are driven by the primary; secondary anims are evaluated
    // at those same progress values. For the canonical AE SMIL export pattern
    // (replace translate with spline keyframes + sum scale that holds across
    // only 2 keyframes) primary is the translate, so we preserve its splines.
    final primary = anims.reduce((a, b) =>
        a.keyframes.keyTimes.length >= b.keyframes.keyTimes.length ? a : b);
    final baseTimes = primary.keyframes.keyTimes;
    final kMode = primary.keyframes.calcMode;
    final baseDur = primary.durSeconds;

    // If any rotate anim sweeps >120° across a primary segment, insert
    // intermediate sample points. `decomposeTRS` wraps the rotation to
    // [-180°, 180°] via atan2, so a raw 0°→360° sweep decomposed only at its
    // endpoints collapses to 0°→0° (identity at both ends of the pivot chain)
    // — nothing rotates. Subdividing captures the intermediate angles; the
    // unwrap step below makes them monotonic for Lottie's linear interp.
    final kTimes = _expandTimesForRotation(anims, baseTimes);
    final subdivided = kTimes.length > baseTimes.length;

    final pKfs = <LottieVectorKeyframe>[];
    final sKfs = <LottieVectorKeyframe>[];
    final rKfs = <LottieScalarKeyframe>[];

    for (var i = 0; i < kTimes.length; i++) {
      final t = kTimes[i];
      var mid = mGroupBase;
      for (final anim in anims) {
        final animMat = _sampleAnimMat(anim, t);
        mid = anim.additive == SvgAnimationAdditive.replace
            ? animMat
            : mid.multiply(animMat);
      }
      final full = mBefore.multiply(mid).multiply(mAfter);
      final trs = full.decomposeTRS();
      final frame = t * baseDur * frameRate;

      final hold = kMode == SvgAnimationCalcMode.discrete;
      BezierHandle? outH;
      BezierHandle? inH;
      // Preserve the primary's bezier handles only when the grid matches
      // its keyTimes 1:1. After subdivision, segment indices no longer align,
      // so fall back to linear handles (null → Lottie default linear).
      if (!hold && !subdivided) {
        if (i == 0) {
          outH = _primaryOutHandle(primary, 0);
        } else {
          inH = _primaryInHandle(primary, i - 1);
          if (i < kTimes.length - 1) {
            outH = _primaryOutHandle(primary, i);
          }
        }
      }

      pKfs.add(LottieVectorKeyframe(
        time: frame,
        start: [trs.tx, trs.ty],
        hold: hold,
        bezierOut: outH,
        bezierIn: inH,
      ));
      sKfs.add(LottieVectorKeyframe(
        time: frame,
        start: [trs.sx * 100, trs.sy * 100],
        hold: hold,
        bezierOut: outH,
        bezierIn: inH,
      ));
      rKfs.add(LottieScalarKeyframe(
        time: frame,
        start: trs.rotDeg,
        hold: hold,
        bezierOut: outH,
        bezierIn: inH,
      ));
    }

    _unwrapRotationKeyframes(rKfs);

    final position = _collapseVector(pKfs);
    final scale = _collapseVector(sKfs);
    final rotation = _collapseScalar(rKfs);

    final opacity = _buildOpacity(inheritedNonTransform, leafOwnNonTransform);

    return LottieTransform(
      anchor: const LottieVectorStatic([0, 0]),
      position: position,
      scale: scale,
      rotation: rotation,
      opacity: opacity,
    );
  }

  BezierHandle _primaryOutHandle(SvgAnimateTransform primary, int segment) {
    final kf = primary.keyframes;
    if (kf.calcMode == SvgAnimationCalcMode.spline &&
        segment < kf.keySplines.length) {
      final s = kf.keySplines[segment];
      return BezierHandle(s.x1, s.y1);
    }
    return const BezierHandle(1, 1);
  }

  BezierHandle _primaryInHandle(SvgAnimateTransform primary, int segment) {
    final kf = primary.keyframes;
    if (kf.calcMode == SvgAnimationCalcMode.spline &&
        segment < kf.keySplines.length) {
      final s = kf.keySplines[segment];
      return BezierHandle(s.x2, s.y2);
    }
    return const BezierHandle(0, 0);
  }

  LottieVectorProp _collapseVector(List<LottieVectorKeyframe> kfs) {
    if (kfs.isEmpty) return const LottieVectorStatic([0, 0]);
    final first = kfs.first.start;
    final allSame = kfs.every((k) =>
        k.start.length == first.length &&
        () {
          for (var i = 0; i < first.length; i++) {
            if ((k.start[i] - first[i]).abs() > 1e-6) return false;
          }
          return true;
        }());
    if (allSame) return LottieVectorStatic(first);
    return LottieVectorAnimated(kfs);
  }

  LottieScalarProp _collapseScalar(List<LottieScalarKeyframe> kfs) {
    if (kfs.isEmpty) return const LottieScalarStatic(0);
    final first = kfs.first.start;
    final allSame = kfs.every((k) => (k.start - first).abs() < 1e-6);
    if (allSame) return LottieScalarStatic(first);
    return LottieScalarAnimated(kfs);
  }

  LottieScalarProp _buildOpacity(
    List<SvgAnimationNode> inherited,
    List<SvgAnimationNode> own,
  ) {
    final displays = <SvgAnimate>[];
    final opacities = <SvgAnimate>[];
    for (final a in [...inherited, ...own].whereType<SvgAnimate>()) {
      if (a.attributeName == 'opacity') {
        opacities.add(a);
      } else if (a.attributeName == 'display') {
        displays.add(a);
      }
    }
    return _opacityMerger.merge(displays: displays, opacities: opacities);
  }

  /// Maps an animated chain `mBefore · T(p) · R/S(t) · T(q) · mAfter` into
  /// Lottie's native anchor/position/rotation/scale when every static segment
  /// is pure translation. Returns `null` when the chain has non-translation
  /// components (rotate/scale/skew statics, matrix, or unsupported additive
  /// patterns) — caller must fall back to general matrix baking.
  ///
  /// Why: baking the full chain into position produces visually correct but
  /// perceptually wrong motion — the layer origin sweeps a circle around the
  /// pivot instead of the layer staying put while rotating. Lottie's
  /// `anchor` is exactly the field for "rotate around this point without
  /// moving," so route the pivot there.
  ///
  /// Derivation: for any rotation `R` and scale `S`, the identity
  ///   `T(b) · T(p) · R·S · T(q) · p_local`
  ///   `   = (b + p) + R·S·(q + p_local)`
  ///   `   = position + R·S·(p_local - anchor)` with
  ///   `     position = b + p`, `anchor = -q`
  /// holds *for every t* independent of R(t) and S(t). The anchor is chosen
  /// so the child's T(-pivot) (typical of AE/Figma pivot exports) becomes
  /// the rotation pivot instead of a constant translation the baker has to
  /// undo on every frame.
  LottieTransform? _buildAnchorPivotTransform({
    required _Mat mBefore,
    required _Mat mGroupBase,
    required _Mat mAfter,
    required List<SvgAnimateTransform> anims,
    required List<SvgAnimationNode> inheritedNonTransform,
    required List<SvgAnimationNode> leafOwnNonTransform,
  }) {
    if (!_isPureTranslation(mBefore)) return null;
    if (!_isPureTranslation(mAfter)) return null;
    if (!_isPureTranslation(mGroupBase)) return null;
    for (final a in anims) {
      switch (a.kind) {
        case SvgTransformKind.translate:
          // sum-translate is the SMIL pivot-offset idiom handled by
          // TransformMapper via anchor; let the general bake cover that
          // mixed case so we don't double-assign anchor.
          if (a.additive != SvgAnimationAdditive.replace) return null;
        case SvgTransformKind.rotate:
        case SvgTransformKind.scale:
          break;
        case SvgTransformKind.matrix:
        case SvgTransformKind.skewX:
        case SvgTransformKind.skewY:
          return null;
      }
    }

    final animatedXf = _transforms.map(animations: anims);

    final bx = mBefore.e, by = mBefore.f;
    final gx = mGroupBase.e, gy = mGroupBase.f;
    final ax = mAfter.e, ay = mAfter.f;

    final anchor = LottieVectorStatic([-ax, -ay]);

    final LottieVectorProp position;
    if (animatedXf.position != null) {
      position = _offsetVectorProp(animatedXf.position!, bx, by);
    } else {
      position = LottieVectorStatic([bx + gx, by + gy]);
    }
    final rotation = animatedXf.rotation ?? const LottieScalarStatic(0);
    final scale = animatedXf.scale ?? const LottieVectorStatic([100, 100]);
    final opacity = _buildOpacity(inheritedNonTransform, leafOwnNonTransform);

    return LottieTransform(
      anchor: anchor,
      position: position,
      scale: scale,
      rotation: rotation,
      opacity: opacity,
    );
  }

  bool _isPureTranslation(_Mat m) =>
      (m.a - 1).abs() < 1e-9 &&
      m.b.abs() < 1e-9 &&
      m.c.abs() < 1e-9 &&
      (m.d - 1).abs() < 1e-9;

  LottieVectorProp _offsetVectorProp(LottieVectorProp p, double dx, double dy) {
    if (dx == 0 && dy == 0) return p;
    switch (p) {
      case LottieVectorStatic():
        return LottieVectorStatic([p.value[0] + dx, p.value[1] + dy]);
      case LottieVectorAnimated():
        return LottieVectorAnimated([
          for (final k in p.keyframes)
            LottieVectorKeyframe(
              time: k.time,
              start: [k.start[0] + dx, k.start[1] + dy],
              hold: k.hold,
              bezierIn: k.bezierIn,
              bezierOut: k.bezierOut,
            ),
        ]);
    }
  }

  /// Subdivides `base` where any rotate anim sweeps more than 120° between
  /// adjacent points. Ensures atan2-based TRS decomposition samples at enough
  /// intermediate angles to reconstruct the full sweep.
  List<double> _expandTimesForRotation(
    List<SvgAnimateTransform> anims,
    List<double> base,
  ) {
    const maxDegPerSegment = 120.0;
    if (base.length < 2) return base;
    final rotates =
        anims.where((a) => a.kind == SvgTransformKind.rotate).toList();
    if (rotates.isEmpty) return base;
    final result = <double>[base.first];
    for (var i = 0; i + 1 < base.length; i++) {
      final t0 = base[i];
      final t1 = base[i + 1];
      var maxSweep = 0.0;
      for (final a in rotates) {
        final v0 = _sampleRotDeg(a, t0);
        final v1 = _sampleRotDeg(a, t1);
        final sweep = (v1 - v0).abs();
        if (sweep > maxSweep) maxSweep = sweep;
      }
      if (maxSweep > maxDegPerSegment) {
        final subs = (maxSweep / maxDegPerSegment).ceil();
        for (var k = 1; k < subs; k++) {
          result.add(t0 + (t1 - t0) * (k / subs));
        }
      }
      result.add(t1);
    }
    return result;
  }

  /// First-component sample (degrees) of a rotate animateTransform at progress
  /// `t ∈ [0, 1]`. Ignores pivot cx/cy; used only for sweep magnitude.
  double _sampleRotDeg(SvgAnimateTransform anim, double t) {
    final kf = anim.keyframes;
    if (kf.values.isEmpty) return 0;
    double first(String raw) => double.parse(
        raw.split(RegExp(r'[ ,]+')).firstWhere((s) => s.isNotEmpty));
    if (t <= kf.keyTimes.first) return first(kf.values.first);
    if (t >= kf.keyTimes.last) return first(kf.values.last);
    var i = 0;
    for (var k = 0; k + 1 < kf.keyTimes.length; k++) {
      if (t >= kf.keyTimes[k] && t <= kf.keyTimes[k + 1]) {
        i = k;
        break;
      }
    }
    if (kf.calcMode == SvgAnimationCalcMode.discrete) return first(kf.values[i]);
    final t0 = kf.keyTimes[i];
    final t1 = kf.keyTimes[i + 1];
    final alpha = (t1 == t0) ? 0.0 : (t - t0) / (t1 - t0);
    final v0 = first(kf.values[i]);
    final v1 = first(kf.values[i + 1]);
    return v0 + (v1 - v0) * alpha;
  }

  /// Makes rotation angles monotonic across keyframes by adding ±360° offsets.
  /// `decomposeTRS` returns angles wrapped to [-180°, 180°] via atan2; without
  /// unwrapping, Lottie's linear interp would animate the *short way* between
  /// jumps and e.g. 170° → -170° would travel 20° backwards instead of 20°
  /// forwards. Modifies `kfs` in place.
  void _unwrapRotationKeyframes(List<LottieScalarKeyframe> kfs) {
    if (kfs.length <= 1) return;
    for (var i = 1; i < kfs.length; i++) {
      var cur = kfs[i].start;
      final prev = kfs[i - 1].start;
      while (cur - prev > 180) {
        cur -= 360;
      }
      while (prev - cur > 180) {
        cur += 360;
      }
      if (cur != kfs[i].start) {
        final k = kfs[i];
        kfs[i] = LottieScalarKeyframe(
          time: k.time,
          start: cur,
          hold: k.hold,
          bezierOut: k.bezierOut,
          bezierIn: k.bezierIn,
        );
      }
    }
  }

  /// Samples an animateTransform at progress `t ∈ [0, 1]` and returns the
  /// corresponding 2D-affine matrix. Interpolates linearly between keyframes
  /// unless calcMode is discrete (hold to the nearest lower keyframe).
  _Mat _sampleAnimMat(SvgAnimateTransform anim, double t) {
    final kf = anim.keyframes;
    final values = kf.values.map(_parseNums).toList();
    if (values.isEmpty) return _Mat.identity();

    if (t <= kf.keyTimes.first) return _toMat(anim.kind, values.first);
    if (t >= kf.keyTimes.last) return _toMat(anim.kind, values.last);

    // Find segment i such that keyTimes[i] <= t <= keyTimes[i+1].
    var i = 0;
    for (var k = 0; k < kf.keyTimes.length - 1; k++) {
      if (t >= kf.keyTimes[k] && t <= kf.keyTimes[k + 1]) {
        i = k;
        break;
      }
    }

    if (kf.calcMode == SvgAnimationCalcMode.discrete) {
      return _toMat(anim.kind, values[i]);
    }
    final t0 = kf.keyTimes[i];
    final t1 = kf.keyTimes[i + 1];
    final alpha = (t1 == t0) ? 0.0 : (t - t0) / (t1 - t0);
    final v0 = values[i];
    final v1 = values[i + 1];
    final lerp = <double>[
      for (var k = 0; k < v0.length; k++) v0[k] + (v1[k] - v0[k]) * alpha,
    ];
    return _toMat(anim.kind, lerp);
  }

  List<double> _parseNums(String raw) => raw
      .split(RegExp(r'[ ,]+'))
      .where((s) => s.isNotEmpty)
      .map(double.parse)
      .toList();

  _Mat _toMat(SvgTransformKind kind, List<double> v) {
    switch (kind) {
      case SvgTransformKind.translate:
        return _Mat.translate(v[0], v.length > 1 ? v[1] : 0);
      case SvgTransformKind.scale:
        final sx = v[0];
        final sy = v.length > 1 ? v[1] : sx;
        return _Mat.scale(sx, sy);
      case SvgTransformKind.rotate:
        final deg = v[0];
        final cx = v.length > 1 ? v[1] : 0.0;
        final cy = v.length > 2 ? v[2] : 0.0;
        if (cx == 0 && cy == 0) return _Mat.rotate(deg);
        return _Mat.translate(cx, cy)
            .multiply(_Mat.rotate(deg))
            .multiply(_Mat.translate(-cx, -cy));
      case SvgTransformKind.matrix:
        return _Mat.fromRowMajor(v);
      case SvgTransformKind.skewX:
      case SvgTransformKind.skewY:
        _log.warn('map.anim', 'skew animateTransform → identity fallback',
            fields: {'kind': kind.name});
        return _Mat.identity();
    }
  }

  _Mat _composeStatics(List<SvgStaticTransform> xs) {
    var m = _Mat.identity();
    for (final x in xs) {
      switch (x.kind) {
        case SvgTransformKind.translate:
          m = m.multiply(_Mat.translate(x.values[0], x.values[1]));
        case SvgTransformKind.scale:
          m = m.multiply(_Mat.scale(x.values[0], x.values[1]));
        case SvgTransformKind.rotate:
          final deg = x.values[0];
          final cx = x.values.length > 1 ? x.values[1] : 0.0;
          final cy = x.values.length > 2 ? x.values[2] : 0.0;
          if (cx == 0 && cy == 0) {
            m = m.multiply(_Mat.rotate(deg));
          } else {
            m = m
                .multiply(_Mat.translate(cx, cy))
                .multiply(_Mat.rotate(deg))
                .multiply(_Mat.translate(-cx, -cy));
          }
        case SvgTransformKind.matrix:
          m = m.multiply(_Mat.fromRowMajor(x.values));
        case SvgTransformKind.skewX:
        case SvgTransformKind.skewY:
          _log.warn('map.compose', 'dropping skew static transform',
              fields: {'kind': x.kind.name});
      }
    }
    return m;
  }
}

class _AnimatedAncestor {
  const _AnimatedAncestor({
    required this.groupStatics,
    required this.anims,
  });
  final List<SvgStaticTransform> groupStatics;
  final List<SvgAnimateTransform> anims;
}

class _TRSFold {
  const _TRSFold(this.tx, this.ty, this.rotDeg, this.sx, this.sy);
  final double tx, ty, rotDeg, sx, sy;
}

/// 2D affine matrix stored in SVG's `matrix(a b c d e f)` convention:
/// ```
/// [ a c e ]
/// [ b d f ]
/// [ 0 0 1 ]
/// ```
class _Mat {
  const _Mat(this.a, this.b, this.c, this.d, this.e, this.f);
  final double a, b, c, d, e, f;

  static _Mat identity() => const _Mat(1, 0, 0, 1, 0, 0);
  static _Mat translate(double tx, double ty) => _Mat(1, 0, 0, 1, tx, ty);
  static _Mat scale(double sx, double sy) => _Mat(sx, 0, 0, sy, 0, 0);
  static _Mat rotate(double deg) {
    final r = deg * math.pi / 180;
    final cs = math.cos(r), sn = math.sin(r);
    return _Mat(cs, sn, -sn, cs, 0, 0);
  }

  static _Mat fromRowMajor(List<double> v) =>
      _Mat(v[0], v[1], v[2], v[3], v[4], v[5]);

  _Mat multiply(_Mat o) => _Mat(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.e + c * o.f + e,
        b * o.e + d * o.f + f,
      );

  _TRSFold decomposeTRS() {
    // Diagonal fast path: matrices without shear / rotation (b≈0 && c≈0).
    // The generic path below picks `rot=180°` + `sy=-sy` to represent a
    // horizontal flip, which is mathematically equivalent but rotates content
    // around the Lottie layer anchor — producing a visible flip on the wrong
    // axis once the layer is parented. Preserving the raw signs keeps
    // `scale(-N, M)` round-trip-clean.
    if (b.abs() < 1e-9 && c.abs() < 1e-9) {
      // Seam-closing bias for mirror-pair sprites. AE/Animate exports the
      // same sticker twice as sibling groups — one with scale(+N, M), one
      // with scale(−N, M) around a shared pivot — so the sprite appears
      // edge-to-edge with its flipped copy (think "butterfly wings"). At
      // rasterisation time Lottie renderers (thorvg in particular) leave a
      // visible transparent strip along the seam because sub-pixel edges
      // of the two halves round independently. Nudging the mirrored side
      // 2 units toward the flip axis overlaps the seam by 2 pixels and
      // erases the gap. Trade-off: a *standalone* `scale(-N)` element
      // (no mirror twin) drifts 2 units from its SVG-exact position —
      // imperceptible at typical sticker sizes (200+ px viewport), and
      // the sign convention (sprite anchored opposite the flip axis) is
      // universal in real-world AE / Figma / Animate exports.
      final tx = a < 0 ? e - 2 : e;
      final ty = d < 0 ? f - 2 : f;
      return _TRSFold(tx, ty, 0, a, d);
    }
    final det = a * d - b * c;
    var sx = math.sqrt(a * a + b * b);
    var sy = math.sqrt(c * c + d * d);
    if (det < 0) sy = -sy;
    final rot = math.atan2(b, a) * 180 / math.pi;
    return _TRSFold(e, f, rot, sx, sy);
  }
}

class _FoldState {
  double value = 0;
}
