import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';

/// Maps SVG SMIL timing (`keyTimes`, `keySplines`, `calcMode`) onto Lottie
/// keyframe bezier handles.
///
/// Lottie convention for two consecutive keyframes K[i] and K[i+1]:
///   K[i].o     = easing out-handle (takes keySpline.x1/y1)
///   K[i+1].i   = easing in-handle  (takes keySpline.x2/y2)
/// K[last] has no spline (animation ends there).
class KeySplineMapper {
  const KeySplineMapper();

  /// Returns the `(bezierOut for K[i], bezierIn for K[i+1])` pair for segment
  /// `i`, or `(null, null)` if the segment has no spline defined.
  (BezierHandle?, BezierHandle?) segment(SvgKeyframes kf, int i) {
    if (kf.calcMode == SvgAnimationCalcMode.discrete) {
      return (null, null);
    }
    if (kf.calcMode != SvgAnimationCalcMode.spline) {
      // linear / paced — Lottie linear default is i:(0,0), o:(1,1).
      return (const BezierHandle(1, 1), const BezierHandle(0, 0));
    }
    if (i < 0 || i >= kf.keySplines.length) {
      return (null, null);
    }
    final s = kf.keySplines[i];
    return (BezierHandle(s.x1, s.y1), BezierHandle(s.x2, s.y2));
  }

  bool hold(SvgKeyframes kf) => kf.calcMode == SvgAnimationCalcMode.discrete;
}
