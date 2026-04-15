import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';
import 'keyspline_mapper.dart';

class OpacityMapper {
  const OpacityMapper({this.frameRate = 60, this.splines = const KeySplineMapper()});

  final double frameRate;
  final KeySplineMapper splines;

  LottieScalarProp map(SvgAnimate anim) {
    assert(anim.attributeName == 'opacity');
    final parsed = anim.keyframes.values.map(double.parse).toList();

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
        start: parsed[i] * 100.0, // Lottie opacity 0..100
        hold: splines.hold(anim.keyframes),
        bezierIn: inH,
        bezierOut: outH,
      ));
    }
    return LottieScalarAnimated(keyframes);
  }
}
