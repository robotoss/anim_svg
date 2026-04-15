import 'package:anim_svg/anim_svg.dart';
import 'package:anim_svg/src/data/mappers/svg_to_lottie_mapper.dart';
import 'package:anim_svg/src/domain/entities/lottie_animation.dart';
import 'package:test/test.dart';

void main() {
  group('nested animated groups → Lottie parenting', () {
    SvgAnimateTransform tx({
      required SvgTransformKind kind,
      required double dur,
      required List<String> values,
      bool infinite = true,
    }) =>
        SvgAnimateTransform(
          kind: kind,
          durSeconds: dur,
          repeatIndefinite: infinite,
          additive: SvgAnimationAdditive.replace,
          keyframes: SvgKeyframes(
            keyTimes: const [0, 1],
            values: values,
            calcMode: SvgAnimationCalcMode.linear,
          ),
        );

    SvgShape leaf() => const SvgShape(
          kind: SvgShapeKind.rect,
          staticTransforms: [],
          animations: [],
          width: 10,
          height: 10,
          fill: 'red',
        );

    SvgDocument wrapDoc(SvgNode root) => SvgDocument(
          width: 100,
          height: 100,
          viewBox: const SvgViewBox(0, 0, 100, 100),
          defs: const SvgDefs({}),
          root: SvgGroup(
            id: 'root',
            staticTransforms: const [],
            animations: const [],
            children: [root],
          ),
        );

    test('2-level equal-dur chain emits 2 null layers + leaf with parent', () {
      final doc = wrapDoc(
        SvgGroup(
          id: 'outer',
          staticTransforms: const [],
          animations: [
            tx(kind: SvgTransformKind.translate, dur: 2, values: ['0,0', '50,0']),
          ],
          children: [
            SvgGroup(
              id: 'inner',
              staticTransforms: const [],
              animations: [
                tx(kind: SvgTransformKind.rotate, dur: 2, values: ['0', '360']),
              ],
              children: [leaf()],
            ),
          ],
        ),
      );

      final out = SvgToLottieMapper().map(doc);
      expect(out.layers.whereType<LottieNullLayer>(), hasLength(2));
      final shapeLayer = out.layers.whereType<LottieShapeLayer>().single;
      expect(shapeLayer.parent, isNotNull);
      // Parent must point at one of the null layers.
      final nullInds =
          out.layers.whereType<LottieNullLayer>().map((l) => l.index).toSet();
      expect(nullInds.contains(shapeLayer.parent), isTrue);
    });

    test('mismatched-dur chain drops inner anim with WARN (no null layers)',
        () {
      final doc = wrapDoc(
        SvgGroup(
          id: 'outer',
          staticTransforms: const [],
          animations: [
            tx(kind: SvgTransformKind.translate, dur: 2, values: ['0,0', '50,0']),
          ],
          children: [
            SvgGroup(
              id: 'inner',
              staticTransforms: const [],
              animations: [
                tx(kind: SvgTransformKind.rotate, dur: 5, values: ['0', '360']),
              ],
              children: [leaf()],
            ),
          ],
        ),
      );

      final out = SvgToLottieMapper().map(doc);
      expect(out.layers.whereType<LottieNullLayer>(), isEmpty);
      expect(out.layers.whereType<LottieShapeLayer>(), hasLength(1));
    });

    test('3-level equal-dur chain emits 3 null layers', () {
      final doc = wrapDoc(
        SvgGroup(
          id: 'l1',
          staticTransforms: const [],
          animations: [
            tx(kind: SvgTransformKind.translate, dur: 2, values: ['0,0', '50,0']),
          ],
          children: [
            SvgGroup(
              id: 'l2',
              staticTransforms: const [],
              animations: [
                tx(kind: SvgTransformKind.rotate, dur: 2, values: ['0', '360']),
              ],
              children: [
                SvgGroup(
                  id: 'l3',
                  staticTransforms: const [],
                  animations: [
                    tx(
                      kind: SvgTransformKind.scale,
                      dur: 2,
                      values: ['1,1', '2,2'],
                    ),
                  ],
                  children: [leaf()],
                ),
              ],
            ),
          ],
        ),
      );

      final out = SvgToLottieMapper().map(doc);
      expect(out.layers.whereType<LottieNullLayer>(), hasLength(3));
      final shapeLayer = out.layers.whereType<LottieShapeLayer>().single;
      expect(shapeLayer.parent, isNotNull);
    });

    test('single-ancestor (depth 1) still bakes without null layers', () {
      final doc = wrapDoc(
        SvgGroup(
          id: 'only',
          staticTransforms: const [],
          animations: [
            tx(kind: SvgTransformKind.translate, dur: 2, values: ['0,0', '50,0']),
          ],
          children: [leaf()],
        ),
      );

      final out = SvgToLottieMapper().map(doc);
      expect(out.layers.whereType<LottieNullLayer>(), isEmpty);
      expect(out.layers.whereType<LottieShapeLayer>(), hasLength(1));
    });
  });
}
