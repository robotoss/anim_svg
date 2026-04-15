import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('negative scale — diagonal-matrix fast path', () {
    test('scale(-1, 1) → ks.s=[-100, 100], ks.r=0', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect x="0" y="0" width="10" height="10" fill="red"
        transform="scale(-1, 1)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final scale = (layer.transform.scale as LottieVectorStatic).value;
      final rot = (layer.transform.rotation as LottieScalarStatic).value;
      expect(scale, [-100.0, 100.0]);
      expect(rot, 0.0);
    });

    test('scale(-2, 2) → ks.s=[-200, 200], ks.r=0', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect x="0" y="0" width="10" height="10" fill="red"
        transform="scale(-2, 2)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final scale = (layer.transform.scale as LottieVectorStatic).value;
      final rot = (layer.transform.rotation as LottieScalarStatic).value;
      expect(scale, [-200.0, 200.0]);
      expect(rot, 0.0);
    });

    test('scale(2, -3) → ks.s=[200, -300], ks.r=0', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect x="0" y="0" width="10" height="10" fill="red"
        transform="scale(2, -3)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final scale = (layer.transform.scale as LottieVectorStatic).value;
      final rot = (layer.transform.rotation as LottieScalarStatic).value;
      expect(scale, [200.0, -300.0]);
      expect(rot, 0.0);
    });

    test('translate + scale(-1, 1) preserves negative sx without rotation', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <g transform="translate(50, 0) scale(-1, 1)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final scale = (layer.transform.scale as LottieVectorStatic).value;
      final rot = (layer.transform.rotation as LottieScalarStatic).value;
      final pos = (layer.transform.position as LottieVectorStatic).value;
      expect(scale, [-100.0, 100.0]);
      expect(rot, 0.0);
      // Seam-closing bias: −1 on x for the mirrored side (sx<0). SVG-exact
      // position would be [50, 0]; the bias overlaps mirror pairs by 1 unit
      // so the visible seam at the shared pivot vanishes in rasterisation.
      expect(pos, [48.0, 0.0]);
    });

    test('mirror seam bias: scale(-2, 2) nudges tx by -1 (fast path)', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <g transform="translate(100, 50) scale(-2, 2)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final pos = (layer.transform.position as LottieVectorStatic).value;
      expect(pos, [98.0, 50.0], reason: 'sx<0 → tx -= 2 for seam overlap');
    });

    test('mirror seam bias: scale(2, -3) nudges ty by -1', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <g transform="translate(20, 30) scale(2, -3)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final pos = (layer.transform.position as LottieVectorStatic).value;
      expect(pos, [20.0, 28.0], reason: 'sy<0 → ty -= 2');
    });

    test('positive scale (no mirror) — no bias applied', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <g transform="translate(40, 60) scale(2, 3)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final pos = (layer.transform.position as LottieVectorStatic).value;
      expect(pos, [40.0, 60.0], reason: 'positive-scale fast path unchanged');
    });

    test('rotate(45) with scale(-1,1) → general path (non-diagonal)', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <g transform="rotate(45) scale(-1, 1)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final rot = (layer.transform.rotation as LottieScalarStatic).value;
      expect(rot.abs(), greaterThan(1.0),
          reason: 'non-diagonal matrix must still flow through the general '
              'decomposition path (atan2 + sign-in-sy)');
    });
  });
}
