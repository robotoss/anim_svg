import 'package:meta/meta.dart';

enum SvgAnimationCalcMode { linear, spline, discrete, paced }

enum SvgAnimationAdditive { replace, sum }

enum SvgTransformKind { translate, scale, rotate, skewX, skewY, matrix }

/// CSS `animation-direction` mapping (W3C CSS Animations L1 §3.4). For SMIL
/// sources this always stays `normal` — SMIL has no equivalent attribute.
enum SvgAnimationDirection { normal, reverse, alternate, alternateReverse }

/// CSS `animation-fill-mode` mapping (W3C CSS Animations L1 §3.7). SMIL
/// sources default to `none` (Lottie holds the last keyframe indefinitely,
/// matching SMIL `fill="freeze"` only when `repeatIndefinite` is false).
enum SvgAnimationFillMode { none, forwards, backwards, both }

@immutable
class SvgKeyframes {
  const SvgKeyframes({
    required this.keyTimes,
    required this.values,
    required this.calcMode,
    this.keySplines = const [],
  });

  final List<double> keyTimes;
  final List<String> values;
  final SvgAnimationCalcMode calcMode;
  final List<BezierSpline> keySplines;
}

@immutable
class BezierSpline {
  const BezierSpline(this.x1, this.y1, this.x2, this.y2);
  final double x1;
  final double y1;
  final double x2;
  final double y2;
}

@immutable
sealed class SvgAnimationNode {
  const SvgAnimationNode({
    required this.durSeconds,
    required this.repeatIndefinite,
    required this.additive,
    required this.keyframes,
    this.delaySeconds = 0,
    this.direction = SvgAnimationDirection.normal,
    this.fillMode = SvgAnimationFillMode.none,
  });

  final double durSeconds;
  final bool repeatIndefinite;
  final SvgAnimationAdditive additive;
  final SvgKeyframes keyframes;

  /// CSS `animation-delay` / SMIL `begin=` offset, in seconds. Positive values
  /// shift the animation forward. Negative values (CSS-only) are clamped to 0
  /// because we can't start keyframes mid-cycle without reshuffling.
  final double delaySeconds;

  /// CSS `animation-direction`. `normal` is the default; `reverse`,
  /// `alternate`, `alternateReverse` are expanded by the mapper into
  /// reshuffled keyframe sequences so the Lottie track stays a plain forward
  /// timeline.
  final SvgAnimationDirection direction;

  /// CSS `animation-fill-mode`. `forwards`/`both` freezes the last keyframe
  /// beyond `dur`; `backwards`/`both` holds the first keyframe during delay.
  /// For `repeatIndefinite` tracks this is a no-op (there is no "after").
  final SvgAnimationFillMode fillMode;
}

@immutable
class SvgAnimate extends SvgAnimationNode {
  const SvgAnimate({
    required this.attributeName,
    required super.durSeconds,
    required super.repeatIndefinite,
    required super.additive,
    required super.keyframes,
    super.delaySeconds,
    super.direction,
    super.fillMode,
  });

  final String attributeName;
}

@immutable
class SvgAnimateTransform extends SvgAnimationNode {
  const SvgAnimateTransform({
    required this.kind,
    required super.durSeconds,
    required super.repeatIndefinite,
    required super.additive,
    required super.keyframes,
    super.delaySeconds,
    super.direction,
    super.fillMode,
  });

  final SvgTransformKind kind;
}
