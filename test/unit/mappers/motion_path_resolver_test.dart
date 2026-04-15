import 'package:anim_svg/anim_svg.dart';
import 'package:anim_svg/src/data/mappers/motion_path_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('MotionPathResolver', () {
    SvgDocument wrap(SvgShape leaf) => SvgDocument(
          width: 100,
          height: 100,
          viewBox: const SvgViewBox(0, 0, 100, 100),
          defs: const SvgDefs({}),
          root: SvgGroup(
            staticTransforms: const [],
            animations: const [],
            children: [leaf],
          ),
        );

    SvgAnimate offsetAnim(List<String> values, {double dur = 2}) => SvgAnimate(
          attributeName: 'offset-distance',
          durSeconds: dur,
          repeatIndefinite: true,
          additive: SvgAnimationAdditive.replace,
          keyframes: SvgKeyframes(
            keyTimes: List.generate(values.length,
                (i) => values.length == 1 ? 0.0 : i / (values.length - 1)),
            values: values,
            calcMode: SvgAnimationCalcMode.linear,
          ),
        );

    test('straight line: offset-distance 0/50/100 → translate(0,0)(50,0)(100,0)',
        () {
      final leaf = SvgShape(
        id: 'sprite',
        staticTransforms: const [],
        animations: [offsetAnim(const ['0%', '50%', '100%'])],
        motionPath: const SvgMotionPath(
          pathData: 'M 0 0 L 100 0',
          rotate: SvgMotionRotate.fixed(0),
        ),
        kind: SvgShapeKind.rect,
        width: 5,
        height: 5,
      );
      final out = const MotionPathResolver().resolve(wrap(leaf));
      final resolved = (out.root.children.single as SvgShape).animations;
      final translate = resolved.whereType<SvgAnimateTransform>().singleWhere(
          (t) => t.kind == SvgTransformKind.translate);
      expect(translate.keyframes.values[0], '0,0');
      expect(translate.keyframes.values[1], startsWith('50'));
      expect(translate.keyframes.values[2], startsWith('100'));
    });

    test('offset-rotate=auto emits a rotate track with path tangent degrees',
        () {
      final leaf = SvgShape(
        id: 'sprite',
        staticTransforms: const [],
        animations: [offsetAnim(const ['0%', '100%'])],
        motionPath: const SvgMotionPath(
          pathData: 'M 0 0 L 0 100',
          // vertical line → tangent 90°
          rotate: SvgMotionRotate.auto(),
        ),
        kind: SvgShapeKind.rect,
        width: 5,
        height: 5,
      );
      final out = const MotionPathResolver().resolve(wrap(leaf));
      final rotates = (out.root.children.single as SvgShape)
          .animations
          .whereType<SvgAnimateTransform>()
          .where((t) => t.kind == SvgTransformKind.rotate)
          .toList();
      expect(rotates, hasLength(1));
      final deg = double.parse(rotates.single.keyframes.values.last);
      expect(deg, closeTo(90, 0.5));
      expect(rotates.single.additive, SvgAnimationAdditive.sum);
    });

    test('offset-rotate=fixed(45) emits a single-value rotate (ignores tangent)',
        () {
      final leaf = SvgShape(
        id: 'sprite',
        staticTransforms: const [],
        animations: [offsetAnim(const ['0%', '100%'])],
        motionPath: const SvgMotionPath(
          pathData: 'M 0 0 L 0 100',
          rotate: SvgMotionRotate.fixed(45),
        ),
        kind: SvgShapeKind.rect,
      );
      final out = const MotionPathResolver().resolve(wrap(leaf));
      final rotates = (out.root.children.single as SvgShape)
          .animations
          .whereType<SvgAnimateTransform>()
          .where((t) => t.kind == SvgTransformKind.rotate)
          .toList();
      expect(rotates, hasLength(1));
      expect(
          rotates.single.keyframes.values.toSet(), equals({'45'}));
    });

    test('orphan offset-distance without offset-path → dropped with WARN', () {
      final leaf = SvgShape(
        id: 'sprite',
        staticTransforms: const [],
        animations: [offsetAnim(const ['0%', '100%'])],
        kind: SvgShapeKind.rect,
      );
      final out = const MotionPathResolver().resolve(wrap(leaf));
      final anims = (out.root.children.single as SvgShape).animations;
      expect(anims, isEmpty);
    });

    test('offset-distance clamps values outside [0,100]%', () {
      final leaf = SvgShape(
        id: 'sprite',
        staticTransforms: const [],
        animations: [offsetAnim(const ['-10%', '110%'])],
        motionPath: const SvgMotionPath(
          pathData: 'M 0 0 L 100 0',
          rotate: SvgMotionRotate.fixed(0),
        ),
        kind: SvgShapeKind.rect,
      );
      final out = const MotionPathResolver().resolve(wrap(leaf));
      final translate = (out.root.children.single as SvgShape)
          .animations
          .whereType<SvgAnimateTransform>()
          .singleWhere((t) => t.kind == SvgTransformKind.translate);
      expect(translate.keyframes.values.first, '0,0');
      expect(translate.keyframes.values.last, startsWith('100'));
    });
  });
}
