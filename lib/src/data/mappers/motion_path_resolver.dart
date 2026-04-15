import 'dart:math' as math;

import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_document.dart';
import '../../domain/entities/svg_motion_path.dart';
import '../parsers/svg_path_data_parser.dart';

/// Resolves CSS Motion Path declarations (`offset-path` + an animated
/// `offset-distance` track) into plain `SvgAnimateTransform` channels
/// (translate, and optionally rotate when `offset-rotate: auto|reverse`).
///
/// The CSS parser emits an `SvgAnimate(attributeName: 'offset-distance')`
/// placeholder because it cannot see the node it belongs to. This resolver
/// walks the document, finds each placeholder, and rewrites it using the
/// node's `motionPath` to sample `(x, y, tangent)` tuples along the path.
///
/// Output semantics:
/// - One `SvgAnimateTransform kind=translate additive=replace` carrying the
///   absolute position at each keyframe. It REPLACES the node's transform
///   stack for its own segment, matching the CSS Motion Path spec which
///   positions the element AT the sampled point (the `transform-origin` is
///   preserved by the leaf's subsequent `sum` channels).
/// - One `SvgAnimateTransform kind=rotate additive=sum` when
///   `offset-rotate=auto` or `reverse`, carrying the path tangent angle in
///   degrees (with 180° flip for `reverse`) at each keyframe.
/// - `offset-rotate: Ndeg` bakes a single static rotate — the path tangent
///   is ignored.
///
/// Keyframe count, `calcMode`, `keySplines`, `delaySeconds`, `direction`,
/// `fillMode` are preserved from the original `offset-distance` track so
/// per-segment easing stays intact.
///
/// Sampling algorithm:
/// - Parse `pathData` once via [SvgPathDataParser] → list of cubic contours.
/// - For each cubic segment flatten into N=32 sub-segments (sufficient for
///   smooth motion along typical AE/Figma export curves; the segments are
///   already continuous tangent-wise, so sub-division error is small).
/// - Cumulative length table keyed by (contour, segment, subSegment).
/// - Lookup at distance `d`: linear search + local interpolation.
/// - Tangent at `t`: cubic Bezier derivative `B'(t)`.
class MotionPathResolver {
  const MotionPathResolver({
    AnimSvgLogger? logger,
    SvgPathDataParser pathParser = const SvgPathDataParser(),
    this.samplesPerSegment = 32,
  })  : _log = logger,
        _pathParser = pathParser;

  final AnimSvgLogger? _log;
  final SvgPathDataParser _pathParser;

  /// Linear sub-divisions per cubic bezier segment used for length
  /// estimation and sampling. 32 keeps per-point error well under 0.5px for
  /// paths up to a few hundred pixels long.
  final int samplesPerSegment;

  SvgDocument resolve(SvgDocument doc) {
    final newRoot = _resolveNode(doc.root) as SvgGroup;
    final newDefs = SvgDefs(
      {
        for (final e in doc.defs.byId.entries) e.key: _resolveNode(e.value),
      },
      gradients: doc.defs.gradients,
      filters: doc.defs.filters,
    );
    return SvgDocument(
      width: doc.width,
      height: doc.height,
      viewBox: doc.viewBox,
      defs: newDefs,
      root: newRoot,
    );
  }

  SvgNode _resolveNode(SvgNode n) {
    List<SvgNode>? newChildren;
    if (n is SvgGroup) {
      newChildren = n.children.map(_resolveNode).toList(growable: false);
    }
    final mp = n.motionPath;
    final hasOffsetDistance = n.animations.any(
      (a) => a is SvgAnimate && a.attributeName == 'offset-distance',
    );
    // If there's no motion-path but an orphan offset-distance track is
    // present, drop it — without the path it's meaningless.
    if (!hasOffsetDistance) {
      return _rebuild(n, n.animations, newChildren);
    }
    if (mp == null) {
      _log?.warn('map.motion-path',
          'offset-distance animation without offset-path → dropping track',
          fields: {'id': n.id ?? ''});
      final filtered = n.animations
          .where((a) =>
              !(a is SvgAnimate && a.attributeName == 'offset-distance'))
          .toList(growable: false);
      return _rebuild(n, filtered, newChildren);
    }
    final sampler = _PathSampler.build(mp.pathData, _pathParser, _log,
        samplesPerSegment: samplesPerSegment);
    if (sampler == null) {
      final filtered = n.animations
          .where((a) =>
              !(a is SvgAnimate && a.attributeName == 'offset-distance'))
          .toList(growable: false);
      return _rebuild(n, filtered, newChildren);
    }
    final out = <SvgAnimationNode>[];
    for (final a in n.animations) {
      if (a is SvgAnimate && a.attributeName == 'offset-distance') {
        out.addAll(_expand(a, mp, sampler));
      } else {
        out.add(a);
      }
    }
    return _rebuild(n, out, newChildren);
  }

  SvgNode _rebuild(
      SvgNode n, List<SvgAnimationNode> anims, List<SvgNode>? newChildren) {
    final animsUnchanged = identical(anims, n.animations) ||
        _identicalAnims(n.animations, anims);
    final childrenUnchanged = newChildren == null ||
        (n is SvgGroup && _identicalNodes(n.children, newChildren));
    if (animsUnchanged && childrenUnchanged) return n;
    switch (n) {
      case SvgGroup():
        return SvgGroup(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: anims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          children: newChildren ?? n.children,
          displayNone: n.displayNone,
        );
      case SvgImage():
        return SvgImage(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: anims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          href: n.href,
          width: n.width,
          height: n.height,
        );
      case SvgUse():
        return SvgUse(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: anims,
          filterId: n.filterId,
          motionPath: n.motionPath,
          hrefId: n.hrefId,
          width: n.width,
          height: n.height,
        );
      case SvgShape():
        return SvgShape(
          id: n.id,
          staticTransforms: n.staticTransforms,
          animations: anims,
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

  bool _identicalAnims(List<SvgAnimationNode> a, List<SvgAnimationNode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  bool _identicalNodes(List<SvgNode> a, List<SvgNode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  List<SvgAnimationNode> _expand(
    SvgAnimate anim,
    SvgMotionPath mp,
    _PathSampler sampler,
  ) {
    final translates = <String>[];
    final rotates = <String>[];
    final emitRotate = mp.rotate.kind != SvgMotionRotateKind.fixed;
    for (final raw in anim.keyframes.values) {
      final pct = _parsePercent(raw);
      final clamped = pct.clamp(0.0, 1.0);
      if (pct < 0 || pct > 1) {
        _log?.warn('map.motion-path',
            'offset-distance out of [0%,100%] — clamped',
            fields: {'raw': raw});
      }
      final sample = sampler.sampleAt(clamped);
      translates.add('${_fmt(sample.x)},${_fmt(sample.y)}');
      if (emitRotate) {
        var deg = sample.tangentDeg;
        if (mp.rotate.kind == SvgMotionRotateKind.reverse) deg += 180;
        rotates.add(_fmt(deg));
      }
    }
    final out = <SvgAnimationNode>[];
    out.add(SvgAnimateTransform(
      kind: SvgTransformKind.translate,
      durSeconds: anim.durSeconds,
      repeatIndefinite: anim.repeatIndefinite,
      additive: SvgAnimationAdditive.replace,
      keyframes: SvgKeyframes(
        keyTimes: List.of(anim.keyframes.keyTimes),
        values: translates,
        calcMode: anim.keyframes.calcMode,
        keySplines: List.of(anim.keyframes.keySplines),
      ),
      delaySeconds: anim.delaySeconds,
      direction: anim.direction,
      fillMode: anim.fillMode,
    ));
    if (emitRotate) {
      out.add(SvgAnimateTransform(
        kind: SvgTransformKind.rotate,
        durSeconds: anim.durSeconds,
        repeatIndefinite: anim.repeatIndefinite,
        additive: SvgAnimationAdditive.sum,
        keyframes: SvgKeyframes(
          keyTimes: List.of(anim.keyframes.keyTimes),
          values: rotates,
          calcMode: anim.keyframes.calcMode,
          keySplines: List.of(anim.keyframes.keySplines),
        ),
        delaySeconds: anim.delaySeconds,
        direction: anim.direction,
        fillMode: anim.fillMode,
      ));
    } else if (mp.rotate.angleDeg != 0) {
      // Static rotate: emit a 1-keyframe track so the angle applies even
      // when other channels are absent. Using a 2-frame identical track
      // keeps downstream invariants (`values.length >= 2`).
      final deg = _fmt(mp.rotate.angleDeg);
      out.add(SvgAnimateTransform(
        kind: SvgTransformKind.rotate,
        durSeconds: anim.durSeconds,
        repeatIndefinite: anim.repeatIndefinite,
        additive: SvgAnimationAdditive.sum,
        keyframes: SvgKeyframes(
          keyTimes: const [0, 1],
          values: [deg, deg],
          calcMode: SvgAnimationCalcMode.linear,
        ),
        delaySeconds: anim.delaySeconds,
        direction: anim.direction,
        fillMode: anim.fillMode,
      ));
    }
    return out;
  }

  double _parsePercent(String raw) {
    final t = raw.trim();
    if (t.endsWith('%')) {
      final n = double.tryParse(t.substring(0, t.length - 1));
      return (n ?? 0) / 100.0;
    }
    final n = double.tryParse(t);
    return n ?? 0;
  }

  String _fmt(double v) {
    if (v.isNaN || v.isInfinite) return '0';
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    return double.parse(v.toStringAsFixed(4)).toString();
  }
}

class _PathSample {
  const _PathSample(this.x, this.y, this.tangentDeg);
  final double x;
  final double y;
  final double tangentDeg;
}

/// Precomputed (x, y, tangent) samples along a flattened cubic path. Built
/// once per node and reused for every keyframe in the `offset-distance`
/// animation.
class _PathSampler {
  _PathSampler._(this._samples, this._totalLen);

  static _PathSampler? build(
    String pathData,
    SvgPathDataParser parser,
    AnimSvgLogger? log, {
    required int samplesPerSegment,
  }) {
    final contours = parser.parse(pathData, logger: log);
    if (contours.isEmpty) {
      log?.warn('map.motion-path', 'offset-path parsed to zero contours',
          fields: {'d': pathData});
      return null;
    }
    // Flatten every contour into a single polyline with tangents. The CSS
    // Motion Path spec treats the entire `offset-path` as one trajectory;
    // we concatenate contours end-to-end (rare for path() values, but
    // possible if the d-string contains multiple `M` commands).
    final samples = <_PathSample>[];
    var cumulative = 0.0;
    final cumulativeLens = <double>[0];
    for (final contour in contours) {
      final n = contour.vertices.length;
      final segmentEnd = contour.closed ? n : n - 1;
      for (var i = 0; i < segmentEnd; i++) {
        final v0 = contour.vertices[i];
        final v1 = contour.vertices[(i + 1) % n];
        final out = contour.outTangents[i];
        final inn = contour.inTangents[(i + 1) % n];
        final p0x = v0[0], p0y = v0[1];
        final p1x = p0x + out[0], p1y = p0y + out[1];
        final p2x = v1[0] + inn[0], p2y = v1[1] + inn[1];
        final p3x = v1[0], p3y = v1[1];
        var prevX = p0x, prevY = p0y;
        final stepCount = samplesPerSegment;
        for (var s = 1; s <= stepCount; s++) {
          final t = s / stepCount;
          final omt = 1 - t;
          final bx = omt * omt * omt * p0x +
              3 * omt * omt * t * p1x +
              3 * omt * t * t * p2x +
              t * t * t * p3x;
          final by = omt * omt * omt * p0y +
              3 * omt * omt * t * p1y +
              3 * omt * t * t * p2y +
              t * t * t * p3y;
          var dx = 3 * omt * omt * (p1x - p0x) +
              6 * omt * t * (p2x - p1x) +
              3 * t * t * (p3x - p2x);
          var dy = 3 * omt * omt * (p1y - p0y) +
              6 * omt * t * (p2y - p1y) +
              3 * t * t * (p3y - p2y);
          // Degenerate-cubic fallback: for straight-line segments (zero
          // tangents) the derivative vanishes at t=0 and t=1. Use the
          // chord direction instead so `offset-rotate: auto` still picks
          // the right angle.
          if (dx * dx + dy * dy < 1e-12) {
            dx = p3x - p0x;
            dy = p3y - p0y;
          }
          final segLen = math
              .sqrt((bx - prevX) * (bx - prevX) + (by - prevY) * (by - prevY));
          cumulative += segLen;
          cumulativeLens.add(cumulative);
          final angle =
              (dx == 0 && dy == 0) ? 0.0 : math.atan2(dy, dx) * 180.0 / math.pi;
          samples.add(_PathSample(bx, by, angle));
          prevX = bx;
          prevY = by;
        }
      }
    }
    if (samples.isEmpty) {
      // Path had only moveTo — no length to animate along. Emit a single
      // sample at the start so keyframes collapse to a static position.
      final first = contours.first.vertices.first;
      samples.add(_PathSample(first[0], first[1], 0));
      cumulativeLens.add(0);
      log?.warn('map.motion-path',
          'offset-path has zero length → static fallback',
          fields: {'d': pathData});
    }
    // Prepend the starting vertex itself as sample[-1] (cumulativeLens[0]=0).
    final startV = contours.first.vertices.first;
    final startAngle = samples.first.tangentDeg;
    final all = <_PathSample>[_PathSample(startV[0], startV[1], startAngle)];
    all.addAll(samples);
    return _PathSampler._(
        _Samples(all, cumulativeLens), cumulative == 0 ? 0 : cumulative);
  }

  final _Samples _samples;
  final double _totalLen;

  _PathSample sampleAt(double pct) {
    if (_totalLen == 0) return _samples.points.first;
    final target = pct * _totalLen;
    final lens = _samples.cumulativeLens;
    // Binary search for the interval containing `target`.
    var lo = 0;
    var hi = lens.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (lens[mid] <= target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = _samples.points[lo];
    final b = _samples.points[hi];
    final segLen = lens[hi] - lens[lo];
    final f = segLen == 0 ? 0.0 : (target - lens[lo]) / segLen;
    final x = a.x + (b.x - a.x) * f;
    final y = a.y + (b.y - a.y) * f;
    // Tangent: use the segment endpoint's tangent — already the derivative
    // at that bezier-t. More stable than lerping two atan2 values (wrap at
    // ±180°). Good enough for the 32-sub-seg flattening we emit.
    final tangent = f < 0.5 ? a.tangentDeg : b.tangentDeg;
    return _PathSample(x, y, tangent);
  }
}

class _Samples {
  const _Samples(this.points, this.cumulativeLens);
  final List<_PathSample> points;
  final List<double> cumulativeLens;
}
