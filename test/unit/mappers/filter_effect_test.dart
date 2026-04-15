import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('filter → Lottie blur effect', () {
    test('shape with filter="url(#f)" produces LottieBlurEffect on layer', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f"><feGaussianBlur stdDeviation="3"/></filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#f)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      expect(layer.effects, hasLength(1));
      final effect = layer.effects.single as LottieBlurEffect;
      final blurriness = effect.blurriness as LottieScalarStatic;
      // Lottie blur radius ≈ SVG stdDeviation × 2.
      expect(blurriness.value, 6);
    });

    test('group-level filter propagates to descendant leaf', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f"><feGaussianBlur stdDeviation="1"/></filter>
  </defs>
  <g filter="url(#f)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      expect(layer.effects, hasLength(1));
    });

    test('feGaussianBlur + feColorMatrix saturate → blur + hue/sat effects',
        () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f">
      <feGaussianBlur stdDeviation="2"/>
      <feColorMatrix type="saturate" values="1.5"/>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#f)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      expect(layer.effects, hasLength(2));
      expect(layer.effects.whereType<LottieBlurEffect>(), hasLength(1));
      expect(layer.effects.whereType<LottieHueSaturationEffect>(), hasLength(1));
    });

    test('serializer emits ef array with ty:29 blur effect', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f"><feGaussianBlur stdDeviation="4"/></filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#f)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final map = const LottieSerializer().toMap(lottie);
      final layers = map['layers'] as List;
      final layer = layers.single as Map<String, dynamic>;
      final ef = layer['ef'] as List;
      expect(ef, hasLength(1));
      final blur = ef.single as Map<String, dynamic>;
      expect(blur['ty'], 29);
      expect(blur['nm'], 'Gaussian Blur');
      final params = blur['ef'] as List;
      final blurriness = params.first as Map<String, dynamic>;
      final v = blurriness['v'] as Map<String, dynamic>;
      expect(v['a'], 0);
      expect(v['k'], 8.0); // 4 × 2
    });
  });
}
