import '../../core/logger.dart';
import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';
import 'keyspline_mapper.dart';

class AnimatedTransform {
  AnimatedTransform({
    this.position,
    this.scale,
    this.rotation,
    this.anchor,
  });

  LottieVectorProp? position;
  LottieVectorProp? scale;
  LottieScalarProp? rotation;

  /// Encodes SMIL "scale around pivot" idiom: `additive="sum"` translate
  /// that appears alongside a `replace`-translate. We map it to Lottie's
  /// anchor (with sign flipped), so rotate/scale pivot around it naturally.
  LottieVectorProp? anchor;
}

/// Converts a list of `<animateTransform>` into Lottie transform properties.
///
/// SMIL emits "scale around pivot" as a chain of animateTransforms on a
/// single element:
///
/// ```
/// additive="replace" type="translate" values="px,py;..."     → ks.p (position)
/// additive="sum"     type="scale"     values="sx,sy;..."     → ks.s (scale)
/// additive="sum"     type="rotate"    values="deg,0,0;..."   → ks.r (rotation)
/// additive="sum"     type="translate" values="-ax,-ay;..."   → ks.a (anchor, sign-flipped)
/// ```
///
/// The last line is SVG's way of shifting the pivot: the inner translate is
/// applied before scale/rotate, so the transformed point is
/// `p + R·s·(P + pivot)`. Setting Lottie anchor to `-pivot` reproduces that
/// exactly, since Lottie computes `p + R·s·(P - a)`.
class TransformMapper {
  TransformMapper({
    this.frameRate = 60,
    this.splines = const KeySplineMapper(),
    AnimSvgLogger? logger,
  }) : _log = logger ?? SilentLogger();

  final double frameRate;
  final KeySplineMapper splines;
  final AnimSvgLogger _log;

  AnimatedTransform map({
    required List<SvgAnimateTransform> animations,
  }) {
    final result = AnimatedTransform();

    // Bucket animations by (kind, role). For translate we distinguish
    // replace (→ position) from sum (→ anchor); scale/rotate collapse into
    // one slot each.
    SvgAnimateTransform? positionAnim;
    SvgAnimateTransform? anchorAnim;
    SvgAnimateTransform? scaleAnim;
    SvgAnimateTransform? rotateAnim;

    for (final anim in animations) {
      switch (anim.kind) {
        case SvgTransformKind.translate:
          if (anim.additive == SvgAnimationAdditive.replace) {
            if (positionAnim != null) {
              _log.warn('map.transform', 'duplicate replace-translate; keeping first');
              continue;
            }
            positionAnim = anim;
          } else {
            if (anchorAnim != null) {
              _log.warn('map.transform', 'duplicate sum-translate; keeping first');
              continue;
            }
            anchorAnim = anim;
          }
        case SvgTransformKind.scale:
          if (scaleAnim != null) {
            _log.warn('map.transform', 'duplicate scale anim; keeping first');
            continue;
          }
          scaleAnim = anim;
        case SvgTransformKind.rotate:
          if (rotateAnim != null) {
            _log.warn('map.transform', 'duplicate rotate anim; keeping first');
            continue;
          }
          rotateAnim = anim;
        case SvgTransformKind.skewX:
        case SvgTransformKind.skewY:
        case SvgTransformKind.matrix:
          _log.warn('map.transform', 'skipping skew/matrix animateTransform',
              fields: {'kind': anim.kind.name});
      }
    }

    if (positionAnim != null) {
      result.position = _vectorKeyframes(positionAnim, dims: 2, scale: 1);
    }
    if (scaleAnim != null) {
      result.scale = _vectorKeyframes(scaleAnim, dims: 2, scale: 100);
    }
    if (rotateAnim != null) {
      // rotate values may be "deg" or "deg cx cy"; we keep degrees only.
      result.rotation = _scalarKeyframes(rotateAnim);
    }
    if (anchorAnim != null) {
      // Sign-flip the pivot offset → Lottie anchor.
      result.anchor = _vectorKeyframes(anchorAnim, dims: 2, scale: -1);
    }

    return result;
  }

  LottieVectorProp _vectorKeyframes(
    SvgAnimateTransform anim, {
    required int dims,
    required double scale,
  }) {
    final parsed = <List<double>>[];
    for (final v in anim.keyframes.values) {
      final nums = v
          .split(RegExp(r'[ ,]+'))
          .where((s) => s.isNotEmpty)
          .map(double.parse)
          .toList();
      if (nums.length < dims) {
        // uniform scale: scale="0.5" → [0.5, 0.5]
        parsed.add(List<double>.filled(dims, nums.first * scale));
      } else {
        parsed.add(nums.take(dims).map((n) => n * scale).toList());
      }
    }

    final keyframes = <LottieVectorKeyframe>[];
    for (var i = 0; i < parsed.length; i++) {
      final frame = anim.keyframes.keyTimes[i] * anim.durSeconds * frameRate;
      BezierHandle? inH;
      BezierHandle? outH;
      if (i == 0) {
        final seg = splines.segment(anim.keyframes, 0);
        outH = seg.$1;
      } else {
        final prev = splines.segment(anim.keyframes, i - 1);
        inH = prev.$2;
        if (i < parsed.length - 1) {
          outH = splines.segment(anim.keyframes, i).$1;
        }
      }
      keyframes.add(LottieVectorKeyframe(
        time: frame,
        start: parsed[i],
        hold: splines.hold(anim.keyframes),
        bezierIn: inH,
        bezierOut: outH,
      ));
    }
    return LottieVectorAnimated(keyframes);
  }

  LottieScalarProp _scalarKeyframes(SvgAnimateTransform anim) {
    final parsed = <double>[];
    for (final v in anim.keyframes.values) {
      final nums = v
          .split(RegExp(r'[ ,]+'))
          .where((s) => s.isNotEmpty)
          .map(double.parse)
          .toList();
      parsed.add(nums.first);
    }

    final keyframes = <LottieScalarKeyframe>[];
    for (var i = 0; i < parsed.length; i++) {
      final frame = anim.keyframes.keyTimes[i] * anim.durSeconds * frameRate;
      BezierHandle? inH;
      BezierHandle? outH;
      if (i == 0) {
        outH = splines.segment(anim.keyframes, 0).$1;
      } else {
        inH = splines.segment(anim.keyframes, i - 1).$2;
        if (i < parsed.length - 1) {
          outH = splines.segment(anim.keyframes, i).$1;
        }
      }
      keyframes.add(LottieScalarKeyframe(
        time: frame,
        start: parsed[i],
        hold: splines.hold(anim.keyframes),
        bezierIn: inH,
        bezierOut: outH,
      ));
    }
    return LottieScalarAnimated(keyframes);
  }
}
