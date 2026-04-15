import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('CSS transform-origin', () {
    test('px origin wraps static transforms with translate pre/post', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <g style="transform-origin: 100px 50px;" transform="rotate(90)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      final statics = grp.staticTransforms;
      expect(statics, hasLength(3));
      expect(statics.first.kind, SvgTransformKind.translate);
      expect(statics.first.values, [100.0, 50.0]);
      expect(statics[1].kind, SvgTransformKind.rotate);
      expect(statics.last.kind, SvgTransformKind.translate);
      expect(statics.last.values, [-100.0, -50.0]);
    });

    test('unitless numbers are treated as px', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <g style="transform-origin: 20 30;" transform="scale(2)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      final statics = grp.staticTransforms;
      expect(statics, hasLength(3));
      expect(statics.first.values, [20.0, 30.0]);
      expect(statics.last.values, [-20.0, -30.0]);
    });

    test('single value reuses x as y', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <g style="transform-origin: 40px;" transform="rotate(45)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      final statics = grp.staticTransforms;
      expect(statics, hasLength(3));
      expect(statics.first.values, [40.0, 40.0]);
      expect(statics.last.values, [-40.0, -40.0]);
    });

    test('origin 0 0 does not wrap', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <g style="transform-origin: 0 0;" transform="rotate(90)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      expect(grp.staticTransforms, hasLength(1));
      expect(grp.staticTransforms.single.kind, SvgTransformKind.rotate);
    });

    test('keyword origin (center) is skipped', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <g style="transform-origin: center center;" transform="rotate(90)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      expect(grp.staticTransforms, hasLength(1),
          reason: 'keywords need bbox → skip wrap, keep raw transform');
    });

    test('no transform-origin → statics untouched', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <g transform="translate(10, 20) rotate(45)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      expect(grp.staticTransforms, hasLength(2));
    });

    test('matrix transform with pixel origin — rotation pivot honoured', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600">
  <g style="transform-origin: 289px 399px;"
     transform="matrix(0.39, -0.09, 0.09, 0.39, 159.98, 53.05)">
    <rect x="0" y="0" width="10" height="10" fill="red"/>
  </g>
</svg>''';
      final doc = SvgParser().parse(svg);
      final grp = doc.root.children.single as SvgGroup;
      final statics = grp.staticTransforms;
      expect(statics.length, greaterThanOrEqualTo(3));
      expect(statics.first.kind, SvgTransformKind.translate);
      expect(statics.first.values, [289.0, 399.0]);
      expect(statics.last.kind, SvgTransformKind.translate);
      expect(statics.last.values, [-289.0, -399.0]);
    });
  });
}
