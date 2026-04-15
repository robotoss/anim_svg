import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('feComponentTransfer → Lottie brightness effect', () {
    test('animated linear slope on R/G/B emits LottieBrightnessEffect', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="pulse">
      <feComponentTransfer>
        <feFuncR type="linear" slope="1">
          <animate attributeName="slope" dur="2s" values="1;1.5;1" repeatCount="indefinite"/>
        </feFuncR>
        <feFuncG type="linear" slope="1">
          <animate attributeName="slope" dur="2s" values="1;1.5;1" repeatCount="indefinite"/>
        </feFuncG>
        <feFuncB type="linear" slope="1">
          <animate attributeName="slope" dur="2s" values="1;1.5;1" repeatCount="indefinite"/>
        </feFuncB>
      </feComponentTransfer>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#pulse)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      final effect = layer.effects.whereType<LottieBrightnessEffect>().single;
      final brightness = effect.brightness as LottieScalarAnimated;
      expect(brightness.keyframes, hasLength(3));
      expect(brightness.keyframes.first.start, closeTo(0, 1e-6)); // 1 → 0
      expect(brightness.keyframes[1].start, closeTo(50, 1e-6)); // 1.5 → 50
    });

    test('static slopes at identity → no effect emitted', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="noop">
      <feComponentTransfer>
        <feFuncR type="linear" slope="1"/>
        <feFuncG type="linear" slope="1"/>
        <feFuncB type="linear" slope="1"/>
      </feComponentTransfer>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#noop)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single as LottieShapeLayer;
      expect(layer.effects.whereType<LottieBrightnessEffect>(), isEmpty);
    });

    test('serializer emits ty:22 Brightness & Contrast', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="b">
      <feComponentTransfer>
        <feFuncR type="linear" slope="1.25"/>
        <feFuncG type="linear" slope="1.25"/>
        <feFuncB type="linear" slope="1.25"/>
      </feComponentTransfer>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#b)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final map = const LottieSerializer().toMap(lottie);
      final layer = (map['layers'] as List).single as Map<String, dynamic>;
      final effects = layer['ef'] as List;
      final brightness = effects
          .cast<Map<String, dynamic>>()
          .where((e) => e['mn'] == 'ADBE Brightness & Contrast 2')
          .single;
      expect(brightness['ty'], 22);
    });
  });
}
