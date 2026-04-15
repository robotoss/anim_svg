import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';

/// Maps `<animate attributeName="display" values="none;inline;none">` onto a
/// hold-interpolated opacity track (Lottie has no discrete visibility channel).
///
/// `inline|block|...` → 100; `none` → 0. All keyframes are holds (h:1).
class DisplayMapper {
  const DisplayMapper({this.frameRate = 60});

  final double frameRate;

  LottieScalarProp map(SvgAnimate anim) {
    assert(anim.attributeName == 'display');
    final kf = anim.keyframes;
    final keyframes = <LottieScalarKeyframe>[];
    for (var i = 0; i < kf.values.length; i++) {
      final v = kf.values[i].trim();
      final opacity = v == 'none' ? 0.0 : 100.0;
      final frame = kf.keyTimes[i] * anim.durSeconds * frameRate;
      keyframes.add(LottieScalarKeyframe(
        time: frame,
        start: opacity,
        hold: true,
      ));
    }
    return LottieScalarAnimated(keyframes);
  }
}
