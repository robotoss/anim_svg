import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('feColorMatrix saturate → LottieHueSaturationEffect', () {
    test('static values="2" → masterSaturation=100', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f" x="0" y="0" width="1" height="1">
      <feColorMatrix type="saturate" values="2"/>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" fill="red" filter="url(#f)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final layer = lottie.layers.single;
      expect(layer.effects, hasLength(1));
      final eff = layer.effects.single as LottieHueSaturationEffect;
      expect((eff.masterSaturation as LottieScalarStatic).value, 100.0);
    });

    test('static values="0" → masterSaturation=-100 (greyscale)', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f"><feColorMatrix type="saturate" values="0"/></filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" fill="red" filter="url(#f)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final eff = lottie.layers.single.effects.single
          as LottieHueSaturationEffect;
      expect((eff.masterSaturation as LottieScalarStatic).value, -100.0);
    });

    test('animated values="1;1.4;1" → [0, 40, 0]', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f">
      <feColorMatrix type="saturate" values="1">
        <animate attributeName="values" dur="2s"
                 values="1;1.4;1" keyTimes="0;0.5;1" repeatCount="indefinite"/>
      </feColorMatrix>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" fill="red" filter="url(#f)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final eff = lottie.layers.single.effects.single
          as LottieHueSaturationEffect;
      final anim = eff.masterSaturation as LottieScalarAnimated;
      final values = anim.keyframes.map((k) => k.start).toList();
      expect(values[0], closeTo(0.0, 1e-6));
      expect(values[1], closeTo(40.0, 1e-6));
      expect(values[2], closeTo(0.0, 1e-6));
    });

    test('saturate + feComponentTransfer → two effects on layer', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f">
      <feColorMatrix type="saturate" values="1.5"/>
      <feComponentTransfer>
        <feFuncR type="linear" slope="1.2"/>
        <feFuncG type="linear" slope="1.2"/>
        <feFuncB type="linear" slope="1.2"/>
      </feComponentTransfer>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" fill="red" filter="url(#f)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final effects = lottie.layers.single.effects;
      expect(effects, hasLength(2));
      expect(effects.whereType<LottieHueSaturationEffect>(), hasLength(1));
      expect(effects.whereType<LottieBrightnessEffect>(), hasLength(1));
    });

    test('ty:19 serialises with ADBE HUE SATURATION channel codes', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f"><feColorMatrix type="saturate" values="2"/></filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" fill="red" filter="url(#f)"/>
</svg>''';
      final map = ConvertSvgToLottie().convertToMap(svg);
      final layers = map['layers'] as List;
      final layer = layers.single as Map;
      final ef = layer['ef'] as List;
      expect(ef, hasLength(1));
      final hueSat = ef.single as Map;
      expect(hueSat['ty'], 19);
      expect(hueSat['mn'], 'ADBE HUE SATURATION');
      final channels = hueSat['ef'] as List;
      final masterSat = channels.firstWhere(
          (c) => (c as Map)['nm'] == 'Master Saturation') as Map;
      expect((masterSat['v'] as Map)['k'], 100.0);
    });
  });
}
