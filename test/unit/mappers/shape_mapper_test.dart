import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('ShapeMapper', () {
    test('<rect> → Lottie rc geometry + fill', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.rect,
        x: 10,
        y: 20,
        width: 100,
        height: 50,
        fill: '#ff0000',
      );
      final items = const ShapeMapper().map(node);
      expect(items, hasLength(2));
      final geom = items[0] as LottieShapeGeometry;
      expect(geom.kind, LottieShapeKind.rect);
      expect(geom.rectPosition, [60, 45]); // center
      expect(geom.rectSize, [100, 50]);
      final fill = items[1] as LottieShapeFill;
      expect(fill.color, [1.0, 0.0, 0.0, 1.0]);
      expect(fill.opacity, 100);
    });

    test('<circle> → ellipse geometry with 2r diameter', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.circle,
        cx: 50,
        cy: 50,
        r: 25,
        fill: 'rgb(0, 128, 255)',
      );
      final items = const ShapeMapper().map(node);
      final geom = items.first as LottieShapeGeometry;
      expect(geom.kind, LottieShapeKind.ellipse);
      expect(geom.ellipsePosition, [50, 50]);
      expect(geom.ellipseSize, [50, 50]);
      final fill = items.last as LottieShapeFill;
      expect(fill.color[0], closeTo(0, 1e-9));
      expect(fill.color[1], closeTo(128 / 255, 1e-9));
      expect(fill.color[2], closeTo(1, 1e-9));
    });

    test('<path> d → one LottieShapeGeometry(path)', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.path,
        d: 'M 0 0 L 10 0 L 10 10 Z',
        fill: 'black',
      );
      final items = const ShapeMapper().map(node);
      final geom = items.first as LottieShapeGeometry;
      expect(geom.kind, LottieShapeKind.path);
      expect(geom.vertices, [
        [0, 0],
        [10, 0],
        [10, 10],
      ]);
      expect(geom.closed, isTrue);
    });

    test('fill: url(#grad) → warn + grey fallback', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.circle,
        cx: 0,
        cy: 0,
        r: 10,
        fill: 'url(#gradient-0)',
      );
      final items = const ShapeMapper().map(node);
      final fill = items.whereType<LottieShapeFill>().single;
      expect(fill.color, [0.5, 0.5, 0.5, 1]);
    });

    test('fill: none → no fill emitted', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.path,
        d: 'M 0 0 L 10 0',
        fill: 'none',
      );
      final items = const ShapeMapper().map(node);
      expect(items.whereType<LottieShapeFill>(), isEmpty);
      expect(items.whereType<LottieShapeGeometry>(), hasLength(1));
    });

    test('stroke: #fff width=6 → LottieShapeStroke emitted', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.path,
        d: 'M 0 0 L 10 0',
        fill: 'none',
        stroke: '#ffffff',
        strokeWidth: 6,
        strokeLinecap: 'round',
      );
      final items = const ShapeMapper().map(node);
      final stroke = items.whereType<LottieShapeStroke>().single;
      expect(stroke.color, [1.0, 1.0, 1.0, 1.0]);
      expect(stroke.width, 6);
      expect(stroke.lineCap, 2); // round
    });

    test('stroke-dashoffset animation → LottieShapeTrimPath end animated',
        () {
      const anim = SvgAnimate(
        attributeName: 'stroke-dashoffset',
        durSeconds: 1,
        repeatIndefinite: true,
        additive: SvgAnimationAdditive.replace,
        keyframes: SvgKeyframes(
          keyTimes: [0, 1],
          values: ['100', '0'],
          calcMode: SvgAnimationCalcMode.linear,
        ),
      );
      const node = SvgShape(
        staticTransforms: [],
        animations: [anim],
        kind: SvgShapeKind.path,
        d: 'M 0 0 L 100 0',
        fill: 'none',
        stroke: '#ffffff',
        strokeWidth: 2,
        strokeDasharray: '100',
      );
      final items = const ShapeMapper().map(node);
      final trim = items.whereType<LottieShapeTrimPath>().single;
      expect(trim.start, isA<LottieScalarStatic>());
      expect((trim.start as LottieScalarStatic).value, 0);
      final end = trim.end as LottieScalarAnimated;
      expect(end.keyframes, hasLength(2));
      expect(end.keyframes.first.start, closeTo(0, 1e-6)); // dashoffset=L → 0%
      expect(end.keyframes.last.start, closeTo(100, 1e-6)); // dashoffset=0 → 100%
      // Trim path must come AFTER stroke for Lottie to apply it correctly.
      final strokeIdx = items.indexWhere((i) => i is LottieShapeStroke);
      final trimIdx = items.indexWhere((i) => i is LottieShapeTrimPath);
      expect(trimIdx, greaterThan(strokeIdx));
    });
  });
}
