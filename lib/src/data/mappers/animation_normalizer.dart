import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_document.dart';

/// Bakes CSS-only animation options (`animation-direction`,
/// `animation-delay`, `animation-fill-mode`) into the underlying keyframe
/// arrays so downstream mappers can treat every track as a plain forward
/// timeline with `direction=normal` and `delaySeconds=0`.
///
/// Transformations:
/// - `reverse` → reverse the `values` list in place (keyTimes remain
///   monotone 0..1 and the same spline stack applies segment-wise).
/// - `alternate` → concatenate forward + reversed-tail into a
///   2×length values list; keyTimes scaled to [0,0.5] then [0.5,1];
///   `durSeconds` doubled; keySplines replicated (forward + reversed) per
///   segment.
/// - `alternate-reverse` → same as alternate but start reversed.
/// - `delaySeconds > 0` with finite repeat → prepend a hold keyframe at
///   `t=0` holding `values[0]`; keyTimes rescaled into the new `dur =
///   dur + delay`. For `repeatIndefinite=true`, delay is logged and
///   skipped (Lottie loops the whole outPoint so a pre-roll hold would
///   distort every subsequent cycle).
/// - `fillMode` is left untouched: Lottie layers freeze the last
///   keyframe past `outPoint` by default (`forwards`/`both`). `backwards`
///   with delay is handled implicitly by the prepended hold keyframe.
///
/// The normalizer is pure — it does not mutate the input document. It
/// returns a new tree with rebuilt `SvgNode` subclasses carrying the
/// transformed animation lists.
class AnimationNormalizer {
  const AnimationNormalizer({AnimSvgLogger? logger}) : _log = logger;

  final AnimSvgLogger? _log;

  SvgDocument normalize(SvgDocument doc) {
    final newRoot = _normalizeNode(doc.root) as SvgGroup;
    final newDefs = SvgDefs(
      {
        for (final e in doc.defs.byId.entries) e.key: _normalizeNode(e.value),
      },
      gradients: doc.defs.gradients,
      filters: doc.defs.filters,
    );
    return SvgDocument(
      width: doc.width,
      height: doc.height,
      viewBox: doc.viewBox,
      root: newRoot,
      defs: newDefs,
    );
  }

  SvgNode _normalizeNode(SvgNode n) {
    final newAnims = n.animations.map(_normalizeAnim).toList(growable: false);
    // Short-circuit: if no animation actually changed, return the original
    // node. This avoids rebuilding large subtrees for documents that don't
    // use any CSS-only options (the common path).
    final anyChanged = _anyChanged(n.animations, newAnims);
    switch (n) {
      case SvgGroup():
        final newChildren =
            n.children.map(_normalizeNode).toList(growable: false);
        final childrenChanged = !_identicalList(n.children, newChildren);
        if (!anyChanged && !childrenChanged) return n;
        return SvgGroup(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: newAnims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          children: newChildren,
          displayNone: n.displayNone,
        );
      case SvgImage():
        if (!anyChanged) return n;
        return SvgImage(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: newAnims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          href: n.href,
          width: n.width,
          height: n.height,
        );
      case SvgUse():
        if (!anyChanged) return n;
        return SvgUse(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: newAnims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          hrefId: n.hrefId,
          width: n.width,
          height: n.height,
        );
      case SvgShape():
        if (!anyChanged) return n;
        return SvgShape(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: newAnims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          kind: n.kind,
          d: n.d,
          x: n.x,
          y: n.y,
          width: n.width,
          height: n.height,
          cx: n.cx,
          cy: n.cy,
          r: n.r,
          rx: n.rx,
          ry: n.ry,
          x1: n.x1,
          y1: n.y1,
          x2: n.x2,
          y2: n.y2,
          points: n.points,
          fill: n.fill,
          fillOpacity: n.fillOpacity,
          opacity: n.opacity,
        );
    }
  }

  bool _anyChanged(List<SvgAnimationNode> a, List<SvgAnimationNode> b) {
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return true;
    }
    return false;
  }

  bool _identicalList(List<SvgNode> a, List<SvgNode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  SvgAnimationNode _normalizeAnim(SvgAnimationNode a) {
    var kfs = a.keyframes;
    var dur = a.durSeconds;
    var direction = a.direction;

    // 1) direction: reverse / alternate / alternate-reverse → rebuild values.
    if (direction != SvgAnimationDirection.normal) {
      final reversed = _reversed(kfs);
      switch (direction) {
        case SvgAnimationDirection.reverse:
          kfs = reversed;
        case SvgAnimationDirection.alternate:
          kfs = _concat(kfs, reversed);
          dur = dur * 2;
        case SvgAnimationDirection.alternateReverse:
          kfs = _concat(reversed, kfs);
          dur = dur * 2;
        case SvgAnimationDirection.normal:
          break;
      }
      direction = SvgAnimationDirection.normal;
    }

    // 2) delay: only applied for finite animations. Indefinite loops skip
    //    the delay (see docstring).
    var delaySec = a.delaySeconds;
    if (delaySec > 0) {
      if (a.repeatIndefinite) {
        _log?.warn('map.normalize.anim',
            'animation-delay ignored on repeatIndefinite track',
            fields: {'delay': delaySec});
      } else {
        final totalDur = dur + delaySec;
        final holdFrac = delaySec / totalDur;
        final rescaled = <double>[0];
        rescaled.addAll(kfs.keyTimes.map((t) => holdFrac + t * (1 - holdFrac)));
        final newValues = <String>[kfs.values.first, ...kfs.values];
        // Prepend a discrete hold segment (holdHandle) so the intro phase
        // really freezes — using linear would interpolate from values[0] to
        // values[0], which is a no-op anyway, but discrete conveys intent
        // and avoids emitting a redundant handle.
        final splines = kfs.calcMode == SvgAnimationCalcMode.spline
            ? <BezierSpline>[
                const BezierSpline(0, 0, 1, 1),
                ...kfs.keySplines,
              ]
            : const <BezierSpline>[];
        kfs = SvgKeyframes(
          keyTimes: rescaled,
          values: newValues,
          calcMode: kfs.calcMode,
          keySplines: splines,
        );
        dur = totalDur;
      }
      delaySec = 0;
    }

    // 3) fill-mode: passthrough (documented in class-level comment).

    if (identical(kfs, a.keyframes) &&
        dur == a.durSeconds &&
        direction == a.direction &&
        delaySec == a.delaySeconds) {
      return a;
    }
    switch (a) {
      case SvgAnimateTransform():
        return SvgAnimateTransform(
          kind: a.kind,
          durSeconds: dur,
          repeatIndefinite: a.repeatIndefinite,
          additive: a.additive,
          keyframes: kfs,
          delaySeconds: delaySec,
          direction: direction,
          fillMode: a.fillMode,
        );
      case SvgAnimate():
        return SvgAnimate(
          attributeName: a.attributeName,
          durSeconds: dur,
          repeatIndefinite: a.repeatIndefinite,
          additive: a.additive,
          keyframes: kfs,
          delaySeconds: delaySec,
          direction: direction,
          fillMode: a.fillMode,
        );
    }
  }

  SvgKeyframes _reversed(SvgKeyframes kfs) {
    final n = kfs.keyTimes.length;
    final newTimes = [for (final t in kfs.keyTimes) 1 - t].reversed.toList();
    final newValues = kfs.values.reversed.toList();
    final newSplines = kfs.calcMode == SvgAnimationCalcMode.spline
        ? [
            for (final s in kfs.keySplines.reversed)
              // Mirror the bezier (CSS reverse reflects easing across x=y=0.5).
              BezierSpline(1 - s.x2, 1 - s.y2, 1 - s.x1, 1 - s.y1),
          ]
        : const <BezierSpline>[];
    assert(newTimes.length == n);
    return SvgKeyframes(
      keyTimes: newTimes,
      values: newValues,
      calcMode: kfs.calcMode,
      keySplines: newSplines,
    );
  }

  SvgKeyframes _concat(SvgKeyframes a, SvgKeyframes b) {
    // Halve both tracks and merge, skipping the duplicate mid-point.
    final aTimes = [for (final t in a.keyTimes) t * 0.5];
    final bTimes = [for (final t in b.keyTimes) 0.5 + t * 0.5];
    final times = [...aTimes, ...bTimes.skip(1)];
    final values = [...a.values, ...b.values.skip(1)];
    final splines = a.calcMode == SvgAnimationCalcMode.spline ||
            b.calcMode == SvgAnimationCalcMode.spline
        ? [
            ...a.keySplines,
            ...b.keySplines,
          ]
        : const <BezierSpline>[];
    final mode = (a.calcMode == SvgAnimationCalcMode.spline ||
            b.calcMode == SvgAnimationCalcMode.spline)
        ? SvgAnimationCalcMode.spline
        : a.calcMode;
    return SvgKeyframes(
      keyTimes: times,
      values: values,
      calcMode: mode,
      keySplines: splines,
    );
  }
}
