import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('SvgToLottieMapper pivoted rotation baking', () {
    test(
        'AE/Figma pivot-pair (translate+rotate 360°) routes pivot to Lottie '
        'anchor so the icon spins in place instead of orbiting the origin', () {
      // Outer group pre-translates to pivot (200, 300) and rotates; child
      // rect cancels the translate. Historical bugs:
      //   1. Parser dropped the constant translate → `_tr` had only a
      //      sum-rotate replacing the base, losing the pivot entirely and
      //      rotating around (0, 0).
      //   2. Once the parser kept the translate, the baker composed the full
      //      pivot chain into ks.p, making the layer origin orbit the pivot
      //      on a 400×600 circle — visually the icon would "run across the
      //      image area" instead of spinning in place.
      // The correct representation uses Lottie's native anchor: anchor and
      // position both at the pivot, rotation animated 0→360°, and the layer
      // content stored at SVG-native coords. Rotation around anchor produces
      // no position drift, matching the original SVG semantics.
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 600">
  <style>
    #spin_tr { animation: m 8s linear infinite }
    @keyframes m {
      0%   { transform: translate(200px,300px) rotate(0deg) }
      100% { transform: translate(200px,300px) rotate(360deg) }
    }
  </style>
  <g id="spin_tr" transform="translate(200,300) rotate(0)">
    <rect transform="translate(-200,-300)" x="190" y="290" width="20" height="20" fill="#f00"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final lottie = SvgToLottieMapper().map(doc);
      final spin = lottie.layers.firstWhere((l) => l.name == 'spin_tr');
      final t = spin.transform;

      // Anchor + position at the pivot → rotation pivots in place, no orbit.
      expect(t.anchor, isA<LottieVectorStatic>());
      expect((t.anchor as LottieVectorStatic).value, [200, 300]);
      // Position must not drift — every keyframe (or the static value) has
      // to stay at the pivot so the icon doesn't orbit.
      final p = t.position;
      if (p is LottieVectorStatic) {
        expect(p.value, [200, 300]);
      } else if (p is LottieVectorAnimated) {
        for (final k in p.keyframes) {
          expect(k.start, [200, 300],
              reason: 'constant CSS translate must not animate motion');
        }
      } else {
        fail('unexpected position prop: $p');
      }

      // Rotation actually animates the full 360° sweep, monotonically.
      expect(t.rotation, isA<LottieScalarAnimated>());
      final rkfs = (t.rotation as LottieScalarAnimated).keyframes;
      expect(rkfs.first.start, closeTo(0, 1e-6));
      expect(rkfs.last.start, closeTo(360, 1e-6));
      for (var i = 1; i < rkfs.length; i++) {
        expect(rkfs[i].start, greaterThan(rkfs[i - 1].start));
      }
    });
  });
}
