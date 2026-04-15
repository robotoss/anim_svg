import 'dart:io';

import 'package:anim_svg/anim_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('svg_anim_6.svg (Svgator) yields animated Lottie, op_frames > 1', () async {
    final svg = await File('example/assets/svg_anim_6.svg').readAsString();
    final lottie = ConvertSvgToLottie(logger: SilentLogger()).convert(svg);
    expect(lottie.layers, isNotEmpty,
        reason: 'Svgator SVG should still produce shape layers');
    expect(lottie.outPoint, greaterThan(1.0),
        reason: 'Svgator <script> payload must drive animation; '
            'op_frames==1 means the script was ignored and nothing animates');
    // Svgator's longest track in svg_anim_6 ends near 3900 ms.
    // At 60fps that is ~234 frames. We only assert "substantially > 1" so
    // minor re-timing work later doesn't break the test.
    expect(lottie.outPoint, greaterThan(30.0));
  });
}
