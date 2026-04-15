import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('SvgCssParser', () {
    test('parses @keyframes translate with linear timing', () {
      const css = '''
        #x { animation: m 1s linear infinite }
        @keyframes m {
          0%   { transform: translate(0px, 0px) }
          100% { transform: translate(100px, 0px) }
        }
      ''';
      final out = const SvgCssParser().parse(css).animations;
      expect(out.keys, ['x']);
      final anim = out['x']!.single as SvgAnimateTransform;
      expect(anim.kind, SvgTransformKind.translate);
      expect(anim.durSeconds, 1);
      expect(anim.repeatIndefinite, isTrue);
      expect(anim.additive, SvgAnimationAdditive.replace);
      expect(anim.keyframes.values, ['0,0', '100,0']);
      expect(anim.keyframes.keyTimes, [0, 1]);
      expect(anim.keyframes.calcMode, SvgAnimationCalcMode.linear);
    });

    test('5-stop scale pulse maps to 5 keyTimes', () {
      const css = '''
        #p { animation: s 8000ms linear infinite }
        @keyframes s {
          0%   { transform: scale(1,1) }
          25%  { transform: scale(1.09,1.09) }
          50%  { transform: scale(1,1) }
          75%  { transform: scale(1.09,1.09) }
          100% { transform: scale(1,1) }
        }
      ''';
      final out = const SvgCssParser().parse(css).animations;
      final anim = out['p']!.single as SvgAnimateTransform;
      expect(anim.kind, SvgTransformKind.scale);
      expect(anim.durSeconds, 8);
      expect(anim.keyframes.keyTimes, [0, 0.25, 0.5, 0.75, 1]);
      expect(anim.keyframes.values,
          ['1,1', '1.09,1.09', '1,1', '1.09,1.09', '1,1']);
    });

    test('cubic-bezier timing → spline calcMode with same spline per segment',
        () {
      const css = '''
        #y { animation: m 2s cubic-bezier(.25,.1,.25,1) infinite }
        @keyframes m {
          0%   { transform: translate(0px, 0px) }
          50%  { transform: translate(50px, 0px) }
          100% { transform: translate(100px, 0px) }
        }
      ''';
      final out = const SvgCssParser().parse(css).animations;
      final anim = out['y']!.single as SvgAnimateTransform;
      expect(anim.keyframes.calcMode, SvgAnimationCalcMode.spline);
      expect(anim.keyframes.keySplines, hasLength(2));
      final s = anim.keyframes.keySplines.first;
      expect(s.x1, closeTo(0.25, 1e-9));
      expect(s.y1, closeTo(0.1, 1e-9));
      expect(s.x2, closeTo(0.25, 1e-9));
      expect(s.y2, closeTo(1, 1e-9));
    });

    test(
        'static translate + varying rotate → translate replace + rotate sum '
        '(pivot preserved)', () {
      const css = '''
        #r { animation: m 4s linear infinite }
        @keyframes m {
          0%   { transform: translate(10px,20px) rotate(0deg) }
          100% { transform: translate(10px,20px) rotate(360deg) }
        }
      ''';
      final out = const SvgCssParser().parse(css).animations;
      final anims = out['r']!;
      expect(anims, hasLength(2));
      final tr = anims[0] as SvgAnimateTransform;
      final rot = anims[1] as SvgAnimateTransform;
      expect(tr.kind, SvgTransformKind.translate);
      expect(tr.additive, SvgAnimationAdditive.replace);
      expect(tr.keyframes.values, ['10,20', '10,20']);
      expect(rot.kind, SvgTransformKind.rotate);
      expect(rot.additive, SvgAnimationAdditive.sum);
      expect(rot.keyframes.values, ['0', '360']);
    });

    test('all-static transform emits nothing (no varying channels)', () {
      const css = '''
        #s { animation: m 1s linear infinite }
        @keyframes m {
          0%   { transform: translate(10px,20px) rotate(0deg) }
          100% { transform: translate(10px,20px) rotate(0deg) }
        }
      ''';
      final out = const SvgCssParser().parse(css).animations;
      expect(out['s'], anyOf(isNull, isEmpty));
    });

    test('css without matching @keyframes logs but returns empty', () {
      const css = '#ghost { animation: doesNotExist 1s linear infinite }';
      final out = const SvgCssParser().parse(css).animations;
      expect(out, isEmpty);
    });

    group('angle units', () {
      SvgAnimateTransform rotateOf(String unitExpr) {
        final css = '''
          #a { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: rotate(0deg) }
            100% { transform: rotate($unitExpr) }
          }
        ''';
        return const SvgCssParser().parse(css).animations['a']!.single
            as SvgAnimateTransform;
      }

      test('turn → ×360', () {
        expect(rotateOf('1turn').keyframes.values.last, '360');
      });

      test('rad → ×180/π', () {
        final v = double.parse(rotateOf('3.141592653589793rad')
            .keyframes
            .values
            .last);
        expect(v, closeTo(180, 1e-6));
      });

      test('grad → ×0.9', () {
        expect(rotateOf('100grad').keyframes.values.last, '90');
      });
    });

    group('crash-safety', () {
      test('rotate() with empty args does not throw', () {
        const css = '''
          #x { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: rotate() }
            100% { transform: rotate(90deg) }
          }
        ''';
        expect(() => const SvgCssParser().parse(css).animations, returnsNormally);
      });

      test('matrix() is emitted as matrix kind (mapper may skip)', () {
        const css = '''
          #x { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: matrix(1,0,0,1,0,0) }
            100% { transform: matrix(1,0,0,1,100,0) }
          }
        ''';
        final anims = const SvgCssParser().parse(css).animations['x']!;
        expect(anims, hasLength(1));
        expect((anims.single as SvgAnimateTransform).kind,
            SvgTransformKind.matrix);
      });

      test('transform: none is treated as identity', () {
        const css = '''
          #x { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: none }
            100% { transform: translate(10px,0) }
          }
        ''';
        expect(() => const SvgCssParser().parse(css).animations, returnsNormally);
      });

      test('translate3d drops z; rotateY is skipped with warn', () {
        const css = '''
          #x { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: translate3d(0,0,0) rotateY(0deg) }
            100% { transform: translate3d(10,20,30) rotateY(90deg) }
          }
        ''';
        final anims = const SvgCssParser().parse(css).animations['x']!;
        expect(anims, hasLength(1));
        final tr = anims.single as SvgAnimateTransform;
        expect(tr.kind, SvgTransformKind.translate);
        expect(tr.keyframes.values.last, '10,20');
      });
    });

    test('multi-animation: `animation: a 1s, b 2s` emits both shorthands', () {
      const css = '''
        #x { animation: a 1s linear infinite, b 2s linear infinite }
        @keyframes a { 0% { transform: translate(0,0) } 100% { transform: translate(10,0) } }
        @keyframes b { 0% { transform: rotate(0deg) } 100% { transform: rotate(90deg) } }
      ''';
      final anims = const SvgCssParser().parse(css).animations['x']!;
      expect(anims.whereType<SvgAnimateTransform>().map((a) => a.kind),
          containsAll([SvgTransformKind.translate, SvgTransformKind.rotate]));
      final tr = anims.whereType<SvgAnimateTransform>()
          .firstWhere((a) => a.kind == SvgTransformKind.translate);
      final rot = anims.whereType<SvgAnimateTransform>()
          .firstWhere((a) => a.kind == SvgTransformKind.rotate);
      expect(tr.durSeconds, 1);
      expect(rot.durSeconds, 2);
    });

    test('long-form animation-* synthesises shorthand', () {
      const css = '''
        #x {
          animation-name: m;
          animation-duration: 2s;
          animation-timing-function: ease-in;
          animation-iteration-count: infinite;
        }
        @keyframes m { 0% { transform: translate(0,0) } 100% { transform: translate(5,0) } }
      ''';
      final anims = const SvgCssParser().parse(css).animations['x']!;
      expect(anims, hasLength(1));
      final tr = anims.single as SvgAnimateTransform;
      expect(tr.durSeconds, 2);
      expect(tr.repeatIndefinite, isTrue);
      expect(tr.keyframes.calcMode, SvgAnimationCalcMode.spline);
    });

    test('compound selector `#a, #b` emits under both ids', () {
      const css = '''
        #a, #b { animation: m 1s linear infinite }
        @keyframes m { 0% { transform: translate(0,0) } 100% { transform: translate(10,0) } }
      ''';
      final out = const SvgCssParser().parse(css).animations;
      expect(out.keys.toSet(), {'a', 'b'});
      expect(out['a'], hasLength(1));
      expect(out['b'], hasLength(1));
    });

    test('steps(n) timing → discrete calcMode', () {
      const css = '''
        #x { animation: m 1s steps(4) infinite }
        @keyframes m { 0% { transform: translate(0,0) } 100% { transform: translate(10,0) } }
      ''';
      final anim = const SvgCssParser().parse(css).animations['x']!.single
          as SvgAnimateTransform;
      expect(anim.keyframes.calcMode, SvgAnimationCalcMode.discrete);
      expect(anim.keyframes.keySplines, isEmpty);
    });

    test('pivoted rotate (test_svg_3 pattern) keeps translate as replace', () {
      const css = '''
        #p { animation: m 8s linear infinite }
        @keyframes m {
          0%   { transform: translate(200px,300px) rotate(0deg) }
          100% { transform: translate(200px,300px) rotate(360deg) }
        }
      ''';
      final anims = const SvgCssParser().parse(css).animations['p']!;
      expect(anims, hasLength(2));
      final tr = anims[0] as SvgAnimateTransform;
      final rot = anims[1] as SvgAnimateTransform;
      expect(tr.kind, SvgTransformKind.translate);
      expect(tr.additive, SvgAnimationAdditive.replace);
      expect(tr.keyframes.values, ['200,300', '200,300']);
      expect(rot.kind, SvgTransformKind.rotate);
      expect(rot.additive, SvgAnimationAdditive.sum);
      expect(rot.keyframes.values, ['0', '360']);
    });

    group('per-keyframe animation-timing-function', () {
      test('per-kf cubic-bezier applies to outgoing segment, others linear', () {
        const css = '''
          #a { animation: m 2s linear infinite }
          @keyframes m {
            0%   { transform: translate(0px,0px);
                   animation-timing-function: cubic-bezier(0.4,0,0.6,1) }
            50%  { transform: translate(50px,0px) }
            100% { transform: translate(100px,0px) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['a']!.single
            as SvgAnimateTransform;
        expect(anim.keyframes.calcMode, SvgAnimationCalcMode.spline);
        expect(anim.keyframes.keySplines, hasLength(2));
        final s0 = anim.keyframes.keySplines[0];
        expect(s0.x1, closeTo(0.4, 1e-9));
        expect(s0.y1, closeTo(0, 1e-9));
        expect(s0.x2, closeTo(0.6, 1e-9));
        expect(s0.y2, closeTo(1, 1e-9));
        final s1 = anim.keyframes.keySplines[1];
        expect(s1.x1, 0);
        expect(s1.y1, 0);
        expect(s1.x2, 1);
        expect(s1.y2, 1);
      });

      test('all keyframes carry distinct splines → per-segment splines used',
          () {
        const css = '''
          #b { animation: m 2s linear infinite }
          @keyframes m {
            0%   { transform: translate(0px,0px);
                   animation-timing-function: cubic-bezier(0.1,0.2,0.3,0.4) }
            50%  { transform: translate(50px,0px);
                   animation-timing-function: cubic-bezier(0.5,0.6,0.7,0.8) }
            100% { transform: translate(100px,0px) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['b']!.single
            as SvgAnimateTransform;
        expect(anim.keyframes.calcMode, SvgAnimationCalcMode.spline);
        expect(anim.keyframes.keySplines, hasLength(2));
        expect(anim.keyframes.keySplines[0].x1, closeTo(0.1, 1e-9));
        expect(anim.keyframes.keySplines[0].y2, closeTo(0.4, 1e-9));
        expect(anim.keyframes.keySplines[1].x1, closeTo(0.5, 1e-9));
        expect(anim.keyframes.keySplines[1].y2, closeTo(0.8, 1e-9));
      });

      test('linear shorthand + no per-kf timing → plain linear calcMode', () {
        const css = '''
          #c { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: translate(0px,0px) }
            100% { transform: translate(10px,0px) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['c']!.single
            as SvgAnimateTransform;
        expect(anim.keyframes.calcMode, SvgAnimationCalcMode.linear);
        expect(anim.keyframes.keySplines, isEmpty);
      });
    });

    group('animation-delay / direction / fill-mode', () {
      test('shorthand with two durations: 1st=duration, 2nd=delay', () {
        const css = '''
          #d { animation: m 2s 500ms linear infinite }
          @keyframes m {
            0%   { transform: translate(0,0) }
            100% { transform: translate(10,0) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['d']!.single
            as SvgAnimateTransform;
        expect(anim.durSeconds, 2);
        expect(anim.delaySeconds, closeTo(0.5, 1e-9));
      });

      test('shorthand direction and fill-mode keywords captured', () {
        const css = '''
          #e { animation: m 1s linear infinite alternate forwards }
          @keyframes m {
            0%   { transform: translate(0,0) }
            100% { transform: translate(10,0) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['e']!.single
            as SvgAnimateTransform;
        expect(anim.direction, SvgAnimationDirection.alternate);
        expect(anim.fillMode, SvgAnimationFillMode.forwards);
      });

      test('long-form animation-* overrides defaults', () {
        const css = '''
          #f {
            animation-name: m;
            animation-duration: 1s;
            animation-delay: 250ms;
            animation-direction: reverse;
            animation-fill-mode: both;
            animation-iteration-count: infinite;
          }
          @keyframes m {
            0%   { transform: translate(0,0) }
            100% { transform: translate(10,0) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['f']!.single
            as SvgAnimateTransform;
        expect(anim.delaySeconds, closeTo(0.25, 1e-9));
        expect(anim.direction, SvgAnimationDirection.reverse);
        expect(anim.fillMode, SvgAnimationFillMode.both);
      });

      test('no options → defaults (normal/none/0)', () {
        const css = '''
          #g { animation: m 1s linear infinite }
          @keyframes m {
            0%   { transform: translate(0,0) }
            100% { transform: translate(10,0) }
          }
        ''';
        final anim = const SvgCssParser().parse(css).animations['g']!.single
            as SvgAnimateTransform;
        expect(anim.delaySeconds, 0);
        expect(anim.direction, SvgAnimationDirection.normal);
        expect(anim.fillMode, SvgAnimationFillMode.none);
      });
    });

    group('offset-distance (CSS Motion Path)', () {
      test('keyframe offset-distance emits SvgAnimate with percent values', () {
        const css = '''
          #sprite { animation: move 4s linear infinite }
          @keyframes move {
            0%   { offset-distance: 0% }
            50%  { offset-distance: 60% }
            100% { offset-distance: 100% }
          }
        ''';
        final out = const SvgCssParser().parse(css).animations;
        final anims = out['sprite']!;
        final od = anims
            .whereType<SvgAnimate>()
            .where((a) => a.attributeName == 'offset-distance')
            .single;
        expect(od.durSeconds, 4);
        expect(od.repeatIndefinite, isTrue);
        expect(od.keyframes.values, ['0%', '60%', '100%']);
        expect(od.keyframes.keyTimes, [0, 0.5, 1]);
      });

      test('static offset-distance (single unique value) → dropped', () {
        const css = '''
          #sprite { animation: move 2s linear infinite }
          @keyframes move {
            0%   { offset-distance: 0% }
            100% { offset-distance: 0% }
          }
        ''';
        final out = const SvgCssParser().parse(css).animations;
        final anims = out['sprite'] ?? const [];
        expect(
          anims
              .whereType<SvgAnimate>()
              .where((a) => a.attributeName == 'offset-distance'),
          isEmpty,
        );
      });
    });
  });
}
