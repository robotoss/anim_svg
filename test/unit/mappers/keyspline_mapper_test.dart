import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('KeySplineMapper', () {
    test('spline mode returns correct handles per segment', () {
      final kf = SvgKeyframes(
        keyTimes: const [0, 0.5, 1],
        values: const ['0', '50', '100'],
        calcMode: SvgAnimationCalcMode.spline,
        keySplines: const [
          BezierSpline(0.25, 0.1, 0.25, 1),
          BezierSpline(0.4, 0, 0.6, 1),
        ],
      );
      final m = const KeySplineMapper();

      final seg0 = m.segment(kf, 0);
      expect(seg0.$1!.x, 0.25);
      expect(seg0.$2!.x, 0.25);
      expect(seg0.$2!.y, 1);

      final seg1 = m.segment(kf, 1);
      expect(seg1.$1!.x, 0.4);
      expect(seg1.$2!.y, 1);

      expect(m.hold(kf), isFalse);
    });

    test('discrete mode signals hold and no handles', () {
      final kf = SvgKeyframes(
        keyTimes: const [0, 1],
        values: const ['none', 'inline'],
        calcMode: SvgAnimationCalcMode.discrete,
      );
      final m = const KeySplineMapper();
      expect(m.hold(kf), isTrue);
      final seg = m.segment(kf, 0);
      expect(seg.$1, isNull);
      expect(seg.$2, isNull);
    });
  });
}
