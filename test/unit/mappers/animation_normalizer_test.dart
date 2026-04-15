import 'package:anim_svg/anim_svg.dart';
import 'package:anim_svg/src/data/mappers/animation_normalizer.dart';
import 'package:test/test.dart';

void main() {
  group('AnimationNormalizer', () {
    SvgAnimateTransform buildTx({
      required SvgAnimationDirection direction,
      double delaySec = 0,
      bool infinite = true,
      double dur = 1,
    }) =>
        SvgAnimateTransform(
          kind: SvgTransformKind.translate,
          durSeconds: dur,
          repeatIndefinite: infinite,
          additive: SvgAnimationAdditive.replace,
          keyframes: const SvgKeyframes(
            keyTimes: [0, 1],
            values: ['0,0', '100,0'],
            calcMode: SvgAnimationCalcMode.linear,
          ),
          delaySeconds: delaySec,
          direction: direction,
        );

    SvgDocument wrap(SvgAnimationNode a) => SvgDocument(
          width: 10,
          height: 10,
          viewBox: const SvgViewBox(0, 0, 10, 10),
          defs: const SvgDefs({}),
          root: SvgGroup(
            id: 'r',
            staticTransforms: const [],
            animations: [a],
            children: const [],
          ),
        );

    test('direction=reverse flips values list', () {
      final out = const AnimationNormalizer()
          .normalize(wrap(buildTx(direction: SvgAnimationDirection.reverse)));
      final a = out.root.animations.single as SvgAnimateTransform;
      expect(a.direction, SvgAnimationDirection.normal);
      expect(a.keyframes.values, ['100,0', '0,0']);
      expect(a.keyframes.keyTimes, [0, 1]);
    });

    test('direction=alternate doubles dur and concatenates', () {
      final out = const AnimationNormalizer().normalize(
        wrap(buildTx(direction: SvgAnimationDirection.alternate, dur: 2)),
      );
      final a = out.root.animations.single as SvgAnimateTransform;
      expect(a.direction, SvgAnimationDirection.normal);
      expect(a.durSeconds, 4);
      expect(a.keyframes.values, ['0,0', '100,0', '0,0']);
      expect(a.keyframes.keyTimes, [0, 0.5, 1]);
    });

    test('finite delay prepends hold + grows dur', () {
      final out = const AnimationNormalizer().normalize(
        wrap(buildTx(
          direction: SvgAnimationDirection.normal,
          delaySec: 0.5,
          infinite: false,
          dur: 1.5,
        )),
      );
      final a = out.root.animations.single as SvgAnimateTransform;
      expect(a.delaySeconds, 0);
      expect(a.durSeconds, 2.0);
      expect(a.keyframes.values, ['0,0', '0,0', '100,0']);
      expect(a.keyframes.keyTimes[0], 0);
      expect(a.keyframes.keyTimes[1], closeTo(0.25, 1e-9));
      expect(a.keyframes.keyTimes.last, 1);
    });

    test('delay on repeatIndefinite is skipped (no mutation)', () {
      final out = const AnimationNormalizer().normalize(
        wrap(buildTx(delaySec: 1, direction: SvgAnimationDirection.normal)),
      );
      final a = out.root.animations.single as SvgAnimateTransform;
      expect(a.durSeconds, 1);
      expect(a.keyframes.values, ['0,0', '100,0']);
    });

    test('no-op: normal/no delay returns identical node', () {
      final input = wrap(buildTx(direction: SvgAnimationDirection.normal));
      final out = const AnimationNormalizer().normalize(input);
      expect(identical(out.root, input.root), isTrue);
    });
  });
}
