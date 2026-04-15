import 'dart:io';

import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('SvgParser', () {
    test('parses viewBox, width, height', () {
      final svg = File('test/fixtures/minimal_translate.svg').readAsStringSync();
      final doc = SvgParser().parse(svg);
      expect(doc.width, 100);
      expect(doc.height, 100);
      expect(doc.viewBox.w, 100);
      expect(doc.viewBox.h, 100);
    });

    test('collects defs by id', () {
      final svg = File('test/fixtures/minimal_translate.svg').readAsStringSync();
      final doc = SvgParser().parse(svg);
      expect(doc.defs.byId.keys, contains('a'));
      expect(doc.defs.byId['a'], isA<SvgImage>());
    });

    test('rejects non-<svg> root', () {
      expect(
        () => SvgParser().parse('<foo/>'),
        throwsA(isA<ParseException>()),
      );
    });

    test('skips unsupported element (<foreignObject>) without throwing', () {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">'
          '<foreignObject><div/></foreignObject></svg>';
      final doc = SvgParser().parse(svg);
      expect(doc.root.children, isEmpty);
    });

    test('parses <path> into an SvgShape', () {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
          '<path d="M 0 0 L 10 10 Z" fill="#ff0000"/></svg>';
      final doc = SvgParser().parse(svg);
      final shape = doc.root.children.single as SvgShape;
      expect(shape.kind, SvgShapeKind.path);
      expect(shape.d, 'M 0 0 L 10 10 Z');
      expect(shape.fill, '#ff0000');
    });

    test('parses <use> inside a <g>', () {
      final svg = File('test/fixtures/minimal_use_defs.svg').readAsStringSync();
      final doc = SvgParser().parse(svg);
      final group = doc.root.children.single as SvgGroup;
      expect(group.children, hasLength(2));
      expect(group.children.every((c) => c is SvgUse), isTrue);
    });
  });

  group('SvgParser CSS integration', () {
    test('attaches CSS @keyframes animation to <g id="spin">', () {
      final svg =
          File('test/fixtures/minimal_css_animation.svg').readAsStringSync();
      final doc = SvgParser().parse(svg);
      final group = doc.root.children.single as SvgGroup;
      expect(group.id, 'spin');
      // Static translate + varying rotate emits two tracks so the pivot
      // is preserved when the mapper composes them.
      expect(group.animations, hasLength(2));
      final tr = group.animations[0] as SvgAnimateTransform;
      final rot = group.animations[1] as SvgAnimateTransform;
      expect(tr.kind, SvgTransformKind.translate);
      expect(tr.additive, SvgAnimationAdditive.replace);
      expect(tr.keyframes.values, ['50,50', '50,50']);
      expect(rot.kind, SvgTransformKind.rotate);
      expect(rot.additive, SvgAnimationAdditive.sum);
      expect(rot.durSeconds, 2);
      expect(rot.repeatIndefinite, isTrue);
      expect(rot.keyframes.values, ['0', '360']);
    });

    test('parses offset-path / offset-rotate from inline style', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
  <rect id="sprite" width="10" height="10"
    style="offset-path: path('M 0 0 L 100 0'); offset-rotate: auto" />
</svg>
''';
      final doc = SvgParser().parse(svg);
      final rect = doc.root.children.single as SvgShape;
      expect(rect.motionPath, isNotNull);
      expect(rect.motionPath!.pathData, 'M 0 0 L 100 0');
      expect(rect.motionPath!.rotate.kind, SvgMotionRotateKind.auto);
    });

    test('offset-rotate: 45deg → fixed motion rotate', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
  <g id="g1" style="offset-path: path('M0 0 L10 0'); offset-rotate: 45deg"/>
</svg>
''';
      final g = SvgParser().parse(svg).root.children.single as SvgGroup;
      expect(g.motionPath, isNotNull);
      expect(g.motionPath!.rotate.kind, SvgMotionRotateKind.fixed);
      expect(g.motionPath!.rotate.angleDeg, 45);
    });
  });

  group('SvgParser gradients', () {
    test('parses <linearGradient> with animated <stop offset>', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <linearGradient id="g" gradientUnits="userSpaceOnUse"
        x1="0" y1="0" x2="100" y2="0">
      <stop offset="0" style="stop-color: rgb(255,0,0);"/>
      <stop offset="1" style="stop-color: rgb(0,0,255);">
        <animate attributeName="offset" values="0;1" dur="2s"
                 repeatCount="indefinite"/>
      </stop>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="100" height="10" fill="url(#g)"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      expect(doc.defs.gradients.keys, contains('g'));
      final grad = doc.defs.gradients['g']!;
      expect(grad.kind, SvgGradientKind.linear);
      expect(grad.units, SvgGradientUnits.userSpaceOnUse);
      expect(grad.stops, hasLength(2));
      expect(grad.stops[1].animations, hasLength(1));
      expect((grad.stops[1].animations.single as SvgAnimate).attributeName,
          'offset');
    });
  });

  group('SvgParser filters', () {
    test('parses <filter> with feGaussianBlur + feColorMatrix saturate', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="f">
      <feGaussianBlur stdDeviation="2"/>
      <feColorMatrix type="saturate" values="1.5"/>
      <feComponentTransfer><feFuncR type="linear" slope="1.1"/></feComponentTransfer>
    </filter>
  </defs>
  <rect x="0" y="0" width="10" height="10" filter="url(#f)" fill="red"/>
</svg>''';
      final doc = SvgParser().parse(svg);
      expect(doc.defs.filters.keys, contains('f'));
      final filter = doc.defs.filters['f']!;
      expect(filter.primitives, hasLength(3));
      expect(filter.primitives[0], isA<SvgFilterGaussianBlur>());
      expect((filter.primitives[0] as SvgFilterGaussianBlur).stdDeviation, 2);
      expect(filter.primitives[1], isA<SvgFilterColorMatrix>());
      expect(filter.primitives[2], isA<SvgFilterComponentTransfer>());
      expect((filter.primitives[2] as SvgFilterComponentTransfer).slopeR, 1.1);
      final shape = doc.root.children.single as SvgShape;
      expect(shape.filterId, 'f');
    });
  });

  group('SvgAnimationParser', () {
    test('parses animateTransform translate', () {
      final svg = File('test/fixtures/minimal_translate.svg').readAsStringSync();
      final doc = SvgParser().parse(svg);
      final group = doc.root.children.single as SvgGroup;
      final use = group.children.single as SvgUse;
      final anim = use.animations.single as SvgAnimateTransform;
      expect(anim.kind, SvgTransformKind.translate);
      expect(anim.durSeconds, 1);
      expect(anim.keyframes.values, ['0,0', '50,0']);
      expect(anim.keyframes.keyTimes, [0, 1]);
    });

    test('parses <animate opacity>', () {
      final svg = File('test/fixtures/minimal_opacity.svg').readAsStringSync();
      final doc = SvgParser().parse(svg);
      final use = doc.root.children.single as SvgUse;
      final anim = use.animations.single as SvgAnimate;
      expect(anim.attributeName, 'opacity');
      expect(anim.keyframes.keyTimes, [0, 0.5, 1]);
      expect(anim.keyframes.values, ['1', '0', '1']);
    });
  });
}
