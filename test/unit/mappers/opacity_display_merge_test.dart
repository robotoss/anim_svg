import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

SvgAnimate _display({
  required List<double> keyTimes,
  required List<String> values,
  double durSeconds = 1.0,
}) {
  return SvgAnimate(
    attributeName: 'display',
    durSeconds: durSeconds,
    repeatIndefinite: true,
    additive: SvgAnimationAdditive.replace,
    keyframes: SvgKeyframes(
      keyTimes: keyTimes,
      values: values,
      calcMode: SvgAnimationCalcMode.discrete,
    ),
  );
}

SvgAnimate _opacity({
  required List<double> keyTimes,
  required List<String> values,
  double durSeconds = 1.0,
  SvgAnimationCalcMode calcMode = SvgAnimationCalcMode.linear,
  List<BezierSpline> splines = const [],
}) {
  return SvgAnimate(
    attributeName: 'opacity',
    durSeconds: durSeconds,
    repeatIndefinite: true,
    additive: SvgAnimationAdditive.replace,
    keyframes: SvgKeyframes(
      keyTimes: keyTimes,
      values: values,
      calcMode: calcMode,
      keySplines: splines,
    ),
  );
}

List<LottieScalarKeyframe> _kfs(LottieScalarProp p) =>
    (p as LottieScalarAnimated).keyframes;

double _valueAt(LottieScalarProp p, double frame) {
  if (p is LottieScalarStatic) return p.value;
  final kfs = _kfs(p);
  if (frame < kfs.first.time) return kfs.first.start;
  if (frame >= kfs.last.time) return kfs.last.start;
  for (var i = 0; i + 1 < kfs.length; i++) {
    final a = kfs[i];
    final b = kfs[i + 1];
    if (frame >= a.time && frame < b.time) {
      if (a.hold) return a.start;
      final alpha = (b.time == a.time) ? 0.0 : (frame - a.time) / (b.time - a.time);
      return a.start + (b.start - a.start) * alpha;
    }
  }
  return kfs.last.start;
}

void main() {
  group('OpacityMerger', () {
    test('no inputs → static 100', () {
      final merger = OpacityMerger(frameRate: 60);
      final r = merger.merge(displays: const [], opacities: const []);
      expect(r, isA<LottieScalarStatic>());
      expect((r as LottieScalarStatic).value, 100);
    });

    test('display-only passes through DisplayMapper result', () {
      final merger = OpacityMerger(frameRate: 60);
      final d = _display(
        keyTimes: const [0, 0.5, 1],
        values: const ['none', 'inline', 'inline'],
      );
      final merged = merger.merge(displays: [d], opacities: const []);
      final direct = const DisplayMapper(frameRate: 60).map(d);
      expect(_kfs(merged).length, _kfs(direct).length);
      for (var i = 0; i < _kfs(merged).length; i++) {
        expect(_kfs(merged)[i].time, _kfs(direct)[i].time);
        expect(_kfs(merged)[i].start, _kfs(direct)[i].start);
        expect(_kfs(merged)[i].hold, _kfs(direct)[i].hold);
      }
    });

    test('opacity-only passes through OpacityMapper with keysplines', () {
      final merger = OpacityMerger(frameRate: 60);
      final o = _opacity(
        keyTimes: const [0, 1],
        values: const ['0', '1'],
        calcMode: SvgAnimationCalcMode.spline,
        splines: const [BezierSpline(0.4, 0, 0.2, 1)],
      );
      final merged = merger.merge(displays: const [], opacities: [o]);
      final direct = OpacityMapper(frameRate: 60).map(o);
      expect(_kfs(merged).length, _kfs(direct).length);
      expect(_kfs(merged).first.bezierOut?.x, _kfs(direct).first.bezierOut?.x);
    });

    test('display gate × linear opacity: zero before gate, then ramps', () {
      final merger = OpacityMerger(frameRate: 60);
      final d = _display(
        keyTimes: const [0, 0.5, 1],
        values: const ['none', 'inline', 'inline'],
      );
      final o = _opacity(
        keyTimes: const [0, 1],
        values: const ['0', '1'],
      );
      final r = merger.merge(displays: [d], opacities: [o]);
      // Before gate: 0.
      expect(_valueAt(r, 0), 0);
      expect(_valueAt(r, 15), 0); // frame 15/60 = 0.25s, gate closed
      // At gate open (t=0.5 → frame 30): opacity sample = 50 → product = 50.
      expect(_valueAt(r, 30), closeTo(50, 1e-6));
      // After gate: ramps with opacity.
      expect(_valueAt(r, 60), closeTo(100, 1e-6));
    });

    test('display window with opacity ramp: holds crisp on gate close', () {
      final merger = OpacityMerger(frameRate: 60);
      final d = _display(
        keyTimes: const [0, 0.3, 0.7, 1],
        values: const ['none', 'inline', 'none', 'none'],
      );
      final o = _opacity(
        keyTimes: const [0, 1],
        values: const ['1', '0'],
      );
      final r = merger.merge(displays: [d], opacities: [o]);
      // At t=0.3 (frame 18): display opens, opacity = 1 - 0.3 = 0.7 → 70.
      expect(_valueAt(r, 18), closeTo(70, 1e-6));
      // At t=0.7 (frame 42): display closes exactly → 0.
      expect(_valueAt(r, 42), 0);
      // Inside window at frame 30 (t=0.5): opacity = 0.5 → 50. The pre-step
      // hold kf sits at (gate-close - ε) which nudges the lerp endpoint by
      // one millifrtame, so allow a tiny tolerance.
      expect(_valueAt(r, 30), closeTo(50, 1e-2));
    });

    test('step-then-jump segments are held', () {
      final merger = OpacityMerger(frameRate: 60);
      final d = _display(
        keyTimes: const [0, 0.5, 1],
        values: const ['none', 'inline', 'inline'],
      );
      final o = _opacity(
        keyTimes: const [0, 1],
        values: const ['1', '1'],
      );
      final r = merger.merge(displays: [d], opacities: [o]);
      // kf at t=0 must be hold (step at t=0.5). Otherwise Lottie lerps 0→100.
      final kfs = _kfs(r);
      final zero = kfs.firstWhere((k) => k.time == 0);
      expect(zero.hold, isTrue);
    });

    test('two display gates act as AND', () {
      final merger = OpacityMerger(frameRate: 60);
      final d1 = _display(
        keyTimes: const [0, 0.3, 1],
        values: const ['none', 'inline', 'inline'],
      );
      final d2 = _display(
        keyTimes: const [0, 0.6, 1],
        values: const ['none', 'inline', 'inline'],
      );
      final r = merger.merge(displays: [d1, d2], opacities: const []);
      expect(_valueAt(r, 10), 0); // both closed
      expect(_valueAt(r, 24), 0); // d1 open, d2 still closed
      expect(_valueAt(r, 40), 100); // both open
    });

    test('constant display × constant opacity collapses to static', () {
      final merger = OpacityMerger(frameRate: 60);
      final d = _display(
        keyTimes: const [0, 1],
        values: const ['inline', 'inline'],
      );
      final o = _opacity(
        keyTimes: const [0, 1],
        values: const ['1', '1'],
      );
      final r = merger.merge(displays: [d], opacities: [o]);
      expect(r, isA<LottieScalarStatic>());
      expect((r as LottieScalarStatic).value, closeTo(100, 1e-6));
    });

    test('two opacity animates multiply as fractions', () {
      final merger = OpacityMerger(frameRate: 60);
      final o1 = _opacity(
        keyTimes: const [0, 1],
        values: const ['0.5', '0.5'],
      );
      final o2 = _opacity(
        keyTimes: const [0, 1],
        values: const ['0.5', '0.5'],
      );
      final r = merger.merge(displays: const [], opacities: [o1, o2]);
      // 0.5 × 0.5 × 100 = 25, constant → static.
      expect(r, isA<LottieScalarStatic>());
      expect((r as LottieScalarStatic).value, closeTo(25, 1e-6));
    });
  });
}
