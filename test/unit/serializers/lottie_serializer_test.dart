import 'dart:io';

import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  test('full pipeline: minimal_translate.svg → Lottie map has expected shape',
      () {
    final svg = File('test/fixtures/minimal_translate.svg').readAsStringSync();
    final map = ConvertSvgToLottie().convertToMap(svg);

    expect(map['v'], '5.7.0');
    expect(map['fr'], 60);
    expect(map['w'], 100);
    expect(map['h'], 100);
    expect((map['assets'] as List), hasLength(1));
    expect((map['layers'] as List), hasLength(1));

    final layer = (map['layers'] as List).first as Map<String, dynamic>;
    expect(layer['ty'], 2); // image
    expect(layer['refId'], 'asset_0');

    final ks = layer['ks'] as Map<String, dynamic>;
    final position = ks['p'] as Map<String, dynamic>;
    expect(position['a'], 1);
    final kfs = position['k'] as List;
    expect(kfs, hasLength(2));
    expect((kfs.first as Map)['t'], 0);
    expect((kfs.last as Map)['t'], 60); // 1s * 60fps
  });

  test('opacity animation produces animated ks.o in [0..100]', () {
    final svg = File('test/fixtures/minimal_opacity.svg').readAsStringSync();
    final map = ConvertSvgToLottie().convertToMap(svg);
    final layer = (map['layers'] as List).first as Map<String, dynamic>;
    final opacity = (layer['ks'] as Map<String, dynamic>)['o']
        as Map<String, dynamic>;
    expect(opacity['a'], 1);
    final kfs = opacity['k'] as List;
    expect(kfs, hasLength(3));
    expect((kfs[0] as Map)['s'], [100.0]);
    expect((kfs[1] as Map)['s'], [0.0]);
    expect((kfs[2] as Map)['s'], [100.0]);
  });
}
