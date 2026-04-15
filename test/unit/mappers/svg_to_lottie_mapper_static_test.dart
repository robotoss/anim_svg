import 'dart:io';

import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('SvgToLottieMapper static (no <animate*>)', () {
    test('op is clamped to at least 1 frame', () {
      final svg = File('test/fixtures/minimal_static_image.svg')
          .readAsStringSync();
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      expect(lottie.inPoint, 0);
      expect(lottie.outPoint, 1.0,
          reason: 'Lottie requires op > ip; static SVG must still get 1 frame '
              'so thorvg does not walk into the op==ip degraded codepath '
              '(see ADR-011)');
    });
  });
}
