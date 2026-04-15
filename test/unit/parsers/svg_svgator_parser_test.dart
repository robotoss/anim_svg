import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

/// Wraps a JSON object literal in the IIFE shell that the Svgator exporter
/// emits. The parser looks for `'https://cdn.svgator.com` as a positional
/// marker to locate the payload, so we need to include that literal.
String _wrapPayload(String jsonLiteral) => "(function(){})('h',"
    "$jsonLiteral,"
    "'https://cdn.svgator.com/ply/','__SVGATOR_PLAYER__');";

void main() {
  group('SvgSvgatorParser', () {
    test('returns empty maps when script is blank', () {
      final out = const SvgSvgatorParser().parse('');
      expect(out.animations, isEmpty);
      expect(out.staticTransforms, isEmpty);
    });

    test('returns empty maps when marker URL is absent', () {
      final out = const SvgSvgatorParser().parse('console.log(1);');
      expect(out.animations, isEmpty);
    });

    test('parses a scalar opacity track into SvgAnimate', () {
      final script = _wrapPayload('{"root":"r","animations":[{"elements":{'
          '"a":{"opacity":[{"t":1000,"v":0},{"t":2000,"v":1}]}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anim = out.animations['a']!.single as SvgAnimate;
      expect(anim.attributeName, 'opacity');
      expect(anim.durSeconds, closeTo(1.0, 1e-9));
      expect(anim.delaySeconds, closeTo(1.0, 1e-9));
      expect(anim.keyframes.values, ['0', '1']);
      expect(anim.keyframes.keyTimes, [0.0, 1.0]);
      expect(anim.keyframes.calcMode, SvgAnimationCalcMode.spline);
      expect(anim.keyframes.keySplines.length, 1);
      expect(anim.repeatIndefinite, isTrue);
    });

    test('uses bezier easing from frame e:[…] when provided', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"a":{"opacity":['
          '{"t":0,"v":0,"e":[0.42,0,0.58,1]},'
          '{"t":500,"v":1}'
          ']}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anim = out.animations['a']!.single as SvgAnimate;
      final s = anim.keyframes.keySplines.single;
      expect(s.x1, 0.42);
      expect(s.y1, 0);
      expect(s.x2, 0.58);
      expect(s.y2, 1);
    });

    test('maps transform.keys.t → SvgAnimateTransform translate (replace)', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"b":{"transform":{"keys":{"t":['
          '{"t":0,"v":{"x":0,"y":0}},'
          '{"t":1000,"v":{"x":50,"y":25}}'
          ']}}}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anim = out.animations['b']!.single as SvgAnimateTransform;
      expect(anim.kind, SvgTransformKind.translate);
      expect(anim.additive, SvgAnimationAdditive.replace);
      expect(anim.keyframes.values, ['0,0', '50,25']);
      expect(anim.durSeconds, 1.0);
    });

    test('maps transform.keys.s → scale and keys.r → rotate', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"c":{"transform":{"keys":{'
          '"s":[{"t":0,"v":{"x":1,"y":1}},{"t":500,"v":{"x":2,"y":2}}],'
          '"r":[{"t":0,"v":0},{"t":500,"v":90}]'
          '}}}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anims = out.animations['c']!;
      expect(anims.length, 2);
      final scale = anims.firstWhere(
          (a) => a is SvgAnimateTransform && a.kind == SvgTransformKind.scale)
          as SvgAnimateTransform;
      final rotate = anims.firstWhere(
          (a) => a is SvgAnimateTransform && a.kind == SvgTransformKind.rotate)
          as SvgAnimateTransform;
      expect(scale.keyframes.values, ['1,1', '2,2']);
      expect(rotate.keyframes.values, ['0', '90']);
    });

    test('emits pivot-compensation sum-translate when rotate animated around static origin',
        () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"d":{"transform":{'
          '"data":{"o":{"x":10,"y":20}},'
          '"keys":{"r":[{"t":0,"v":0},{"t":500,"v":180}]}'
          '}}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anims = out.animations['d']!;
      expect(anims.length, 2);
      final anchor = anims.firstWhere((a) =>
          a is SvgAnimateTransform &&
          a.kind == SvgTransformKind.translate &&
          a.additive == SvgAnimationAdditive.sum) as SvgAnimateTransform;
      // Value is negative origin so that the mapper's sign-flip
      // (_vectorKeyframes scale: -1) yields Lottie anchor = +origin.
      expect(anchor.keyframes.values, ['-10,-20', '-10,-20']);
    });

    test('emits static translate for transform.data.t when keys absent', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"e":{"transform":{"data":{"t":{"x":-42,"y":-43}}}}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      expect(out.animations['e'], isNull);
      final st = out.staticTransforms['e']!.single;
      expect(st.kind, SvgTransformKind.translate);
      expect(st.values, [-42.0, -43.0]);
    });

    test('serializes Svgator path command array into SVG path string', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"f":{"d":['
          '{"t":0,"v":["M",0,0,"L",10,10,"Z"]},'
          '{"t":500,"v":["M",5,5,"L",15,15,"Z"]}'
          ']}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anim = out.animations['f']!.single as SvgAnimate;
      expect(anim.attributeName, 'd');
      expect(anim.keyframes.values,
          ['M 0 0 L 10 10 Z', 'M 5 5 L 15 15 Z']);
    });

    test('parses stroke-dashoffset scalar and stroke-dasharray vector', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"g":{'
          '"stroke-dashoffset":[{"t":0,"v":0},{"t":500,"v":100}],'
          '"stroke-dasharray":[{"t":0,"v":[4,4]},{"t":500,"v":[8,2]}]'
          '}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      final anims = out.animations['g']!;
      final offset = anims.firstWhere(
              (a) => a is SvgAnimate && a.attributeName == 'stroke-dashoffset')
          as SvgAnimate;
      final dash = anims.firstWhere(
              (a) => a is SvgAnimate && a.attributeName == 'stroke-dasharray')
          as SvgAnimate;
      expect(offset.keyframes.values, ['0', '100']);
      expect(dash.keyframes.values, ['4,4', '8,2']);
    });

    test('skips single-frame tracks without producing SvgAnimate', () {
      final script = _wrapPayload('{"animations":[{"elements":{'
          '"h":{"opacity":[{"t":1000,"v":0.5}]}'
          '}}]}');
      final out = const SvgSvgatorParser().parse(script);
      expect(out.animations['h'], isNull);
    });

    test('does not touch elements that lack a script payload', () {
      final out = const SvgSvgatorParser()
          .parse("console.log('unrelated script');");
      expect(out.animations, isEmpty);
      expect(out.staticTransforms, isEmpty);
    });
  });
}
