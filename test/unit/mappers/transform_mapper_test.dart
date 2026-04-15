import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  test('translate animation maps to ks.p keyframes at correct frame times', () {
    final anim = SvgAnimateTransform(
      kind: SvgTransformKind.translate,
      durSeconds: 2,
      repeatIndefinite: true,
      additive: SvgAnimationAdditive.replace,
      keyframes: SvgKeyframes(
        keyTimes: const [0, 0.5, 1],
        values: const ['0,0', '10,20', '30,40'],
        calcMode: SvgAnimationCalcMode.linear,
      ),
    );
    final mapped =
        TransformMapper(frameRate: 60).map(animations: [anim]);
    expect(mapped.position, isA<LottieVectorAnimated>());
    final kfs = (mapped.position as LottieVectorAnimated).keyframes;
    expect(kfs, hasLength(3));
    expect(kfs[0].time, 0);
    expect(kfs[1].time, 60); // 0.5 * 2s * 60fps
    expect(kfs[2].time, 120);
    expect(kfs[1].start, [10, 20]);
  });

  test('scale values are converted to percent', () {
    final anim = SvgAnimateTransform(
      kind: SvgTransformKind.scale,
      durSeconds: 1,
      repeatIndefinite: false,
      additive: SvgAnimationAdditive.replace,
      keyframes: SvgKeyframes(
        keyTimes: const [0, 1],
        values: const ['1,1', '0.5,0.5'],
        calcMode: SvgAnimationCalcMode.linear,
      ),
    );
    final mapped =
        TransformMapper().map(animations: [anim]);
    final kfs = (mapped.scale! as LottieVectorAnimated).keyframes;
    expect(kfs.first.start, [100.0, 100.0]);
    expect(kfs.last.start, [50.0, 50.0]);
  });

  test('sum-additive translate maps to ks.a (sign-flipped anchor)', () {
    final replaceT = SvgAnimateTransform(
      kind: SvgTransformKind.translate,
      durSeconds: 1,
      repeatIndefinite: true,
      additive: SvgAnimationAdditive.replace,
      keyframes: SvgKeyframes(
        keyTimes: const [0, 1],
        values: const ['100,200', '150,250'],
        calcMode: SvgAnimationCalcMode.linear,
      ),
    );
    final sumT = SvgAnimateTransform(
      kind: SvgTransformKind.translate,
      durSeconds: 1,
      repeatIndefinite: true,
      additive: SvgAnimationAdditive.sum,
      keyframes: SvgKeyframes(
        keyTimes: const [0, 1],
        values: const ['-10,-20', '-15,-25'],
        calcMode: SvgAnimationCalcMode.linear,
      ),
    );
    final mapped = TransformMapper().map(animations: [replaceT, sumT]);
    final posKfs = (mapped.position! as LottieVectorAnimated).keyframes;
    final anchorKfs = (mapped.anchor! as LottieVectorAnimated).keyframes;
    expect(posKfs.first.start, [100, 200]);
    expect(posKfs.last.start, [150, 250]);
    // sign flipped
    expect(anchorKfs.first.start, [10, 20]);
    expect(anchorKfs.last.start, [15, 25]);
  });

  test('uniform scale "0.5" expands to [50, 50]', () {
    final anim = SvgAnimateTransform(
      kind: SvgTransformKind.scale,
      durSeconds: 1,
      repeatIndefinite: false,
      additive: SvgAnimationAdditive.replace,
      keyframes: SvgKeyframes(
        keyTimes: const [0, 1],
        values: const ['1', '0.5'],
        calcMode: SvgAnimationCalcMode.linear,
      ),
    );
    final mapped =
        TransformMapper().map(animations: [anim]);
    final kfs = (mapped.scale! as LottieVectorAnimated).keyframes;
    expect(kfs.last.start, [50.0, 50.0]);
  });
}
