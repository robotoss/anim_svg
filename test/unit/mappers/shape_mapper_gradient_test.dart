import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('ShapeMapper gradient fills', () {
    test('fill=url(#g) with unknown id → grey fallback (no crash)', () {
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.rect,
        x: 0,
        y: 0,
        width: 10,
        height: 10,
        fill: 'url(#missing)',
      );
      final items = const ShapeMapper().map(node);
      final fill = items.whereType<LottieShapeFill>().single;
      expect(fill.color, [0.5, 0.5, 0.5, 1]);
    });

    test('static linear gradient → LottieShapeGradientFill static', () {
      const grad = SvgGradient(
        id: 'g1',
        kind: SvgGradientKind.linear,
        units: SvgGradientUnits.userSpaceOnUse,
        x1: 0,
        y1: 0,
        x2: 100,
        y2: 0,
        stops: [
          SvgStop(offset: 0, color: '#ff0000'),
          SvgStop(offset: 1, color: '#0000ff'),
        ],
      );
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.rect,
        x: 0,
        y: 0,
        width: 100,
        height: 10,
        fill: 'url(#g1)',
      );
      final items = const ShapeMapper().map(node, gradients: {'g1': grad});
      final gf = items.whereType<LottieShapeGradientFill>().single;
      expect(gf.kind, LottieGradientKind.linear);
      expect(gf.colorStopCount, 2);
      expect(gf.startPoint, [0, 0]);
      expect(gf.endPoint, [100, 0]);
      final s = gf.stops as LottieGradientStopsStatic;
      // [offset, r, g, b] x 2
      expect(s.values, [0, 1, 0, 0, 1, 0, 0, 1]);
    });

    test('animated stop offset → LottieGradientStopsAnimated keyframes', () {
      final grad = SvgGradient(
        id: 'g2',
        kind: SvgGradientKind.linear,
        units: SvgGradientUnits.userSpaceOnUse,
        x1: 0,
        y1: 0,
        x2: 10,
        y2: 0,
        stops: [
          const SvgStop(offset: 0, color: '#000000'),
          SvgStop(
            offset: 0.5,
            color: '#ffffff',
            animations: [
              SvgAnimate(
                attributeName: 'offset',
                durSeconds: 2,
                repeatIndefinite: true,
                additive: SvgAnimationAdditive.replace,
                keyframes: SvgKeyframes(
                  keyTimes: [0, 1],
                  values: ['0', '1'],
                  calcMode: SvgAnimationCalcMode.linear,
                ),
              ),
            ],
          ),
        ],
      );
      const node = SvgShape(
        staticTransforms: [],
        animations: [],
        kind: SvgShapeKind.rect,
        x: 0,
        y: 0,
        width: 10,
        height: 10,
        fill: 'url(#g2)',
      );
      final items = const ShapeMapper(frameRate: 60)
          .map(node, gradients: {'g2': grad});
      final gf = items.whereType<LottieShapeGradientFill>().single;
      final anim = gf.stops as LottieGradientStopsAnimated;
      expect(anim.keyframes, hasLength(2));
      expect(anim.keyframes.first.time, 0);
      // 2 s × 60 fps = 120 frames.
      expect(anim.keyframes.last.time, 120);
      // stop 1 offset goes 0 → 1 (animated); stop 0 offset stays 0.
      expect(anim.keyframes.first.values[0], 0);
      expect(anim.keyframes.first.values[4], 0);
      expect(anim.keyframes.last.values[4], 1);
    });
  });
}
