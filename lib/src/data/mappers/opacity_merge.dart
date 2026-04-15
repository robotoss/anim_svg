import '../../core/logger.dart';
import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';
import 'display_mapper.dart';
import 'opacity_mapper.dart';

/// Merges `<animate attributeName="display">` and `<animate
/// attributeName="opacity">` into a single Lottie opacity track.
///
/// Each display animate acts as a 0/100 step gate; each opacity animate is a
/// 0..100 ramp. The track is sampled at the union of all keyframe times and
/// multiplied as fractions: `100 × Π(v_i / 100)`. Two refinements keep step
/// behaviour crisp inside the Lottie linear-keyframe model:
///
/// - When a step track is 0 across a whole segment the emitted keyframe is
///   held, so the gate-closed value doesn't lerp toward the next sample.
/// - When a ramp runs into a closing gate, a hold pair is inserted at
///   `t_step - epsilon` so the pre-step ramp value lands cleanly before the
///   drop, instead of linearly smearing through the step.
///
/// Single-animate inputs pass straight through to [DisplayMapper] /
/// [OpacityMapper] so keyspline handles survive unchanged.
class OpacityMerger {
  OpacityMerger({
    this.frameRate = 60,
    DisplayMapper? display,
    OpacityMapper? opacity,
    AnimSvgLogger? logger,
  })  : _display = display ?? DisplayMapper(frameRate: frameRate),
        _opacity = opacity ?? OpacityMapper(frameRate: frameRate),
        _log = logger ?? SilentLogger();

  static const double _preStepEpsilonFrames = 1e-3;

  final double frameRate;
  final DisplayMapper _display;
  final OpacityMapper _opacity;
  final AnimSvgLogger _log;

  LottieScalarProp merge({
    required List<SvgAnimate> displays,
    required List<SvgAnimate> opacities,
  }) {
    if (displays.isEmpty && opacities.isEmpty) {
      return const LottieScalarStatic(100);
    }
    if (displays.isEmpty && opacities.length == 1) {
      return _opacity.map(opacities.first);
    }
    if (opacities.isEmpty && displays.length == 1) {
      return _display.map(displays.first);
    }
    if (opacities.any((o) => o.keyframes.keySplines.isNotEmpty)) {
      _log.warn(
        'opacity.merge',
        'dropping opacity keysplines — merge resamples to linear segments',
        fields: {'displays': displays.length, 'opacities': opacities.length},
      );
    }

    final tracks = <_Track>[
      for (final d in displays) _Track.fromDisplay(d, frameRate),
      for (final o in opacities) _Track.fromOpacity(o, frameRate),
    ];
    final timesSet = <double>{};
    for (final t in tracks) {
      for (final s in t.samples) {
        timesSet.add(s.time);
      }
    }
    final times = timesSet.toList()..sort();
    if (times.isEmpty) return const LottieScalarStatic(100);

    final out = <LottieScalarKeyframe>[];
    for (var i = 0; i < times.length; i++) {
      final t = times[i];
      final stepJumpHere = _stepTransitionAt(tracks, t);
      if (i > 0 && stepJumpHere && !out.last.hold) {
        out.add(LottieScalarKeyframe(
          time: t - _preStepEpsilonFrames,
          start: _product(tracks, t, preStep: true),
          hold: true,
        ));
      }
      final value = _product(tracks, t, preStep: false);
      final hold = (i + 1 < times.length) && _segmentHold(tracks, t, times[i + 1]);
      out.add(LottieScalarKeyframe(time: t, start: value, hold: hold));
    }

    final first = out.first.start;
    if (out.every((k) => (k.start - first).abs() < 1e-6)) {
      return LottieScalarStatic(first);
    }
    return LottieScalarAnimated(out);
  }

  double _product(List<_Track> tracks, double t, {required bool preStep}) {
    var p = 1.0;
    for (final trk in tracks) {
      final v = (preStep && trk.isStep) ? trk.sampleJustBefore(t) : trk.sample(t);
      p *= v / 100.0;
    }
    return p * 100.0;
  }

  bool _stepTransitionAt(List<_Track> tracks, double t) {
    for (final trk in tracks) {
      if (!trk.isStep) continue;
      if ((trk.sampleJustBefore(t) - trk.sample(t)).abs() > 1e-6) return true;
    }
    return false;
  }

  /// Hold segment [t0, t1] iff the analytical product is constant on (t0, t1)
  /// but the endpoint values differ. That covers the two practical cases:
  /// gate-closed (a step track is 0) and both tracks static on the segment.
  bool _segmentHold(List<_Track> tracks, double t0, double t1) {
    final p0 = _product(tracks, t0, preStep: false);
    final p1 = _product(tracks, t1, preStep: false);
    if ((p0 - p1).abs() < 1e-6) return false;
    for (final trk in tracks) {
      if (!trk.isStep) continue;
      if (trk.sample(t0).abs() < 1e-6) return true;
    }
    var anyLinearChanges = false;
    for (final trk in tracks) {
      if (trk.isStep) continue;
      if ((trk.sample(t0) - trk.sample(t1)).abs() > 1e-6) {
        anyLinearChanges = true;
        break;
      }
    }
    return !anyLinearChanges;
  }
}

class _Track {
  _Track({required this.samples, required this.isStep});

  final List<_Sample> samples;
  final bool isStep;

  factory _Track.fromDisplay(SvgAnimate a, double fr) {
    final kf = a.keyframes;
    return _Track(
      samples: [
        for (var i = 0; i < kf.values.length; i++)
          _Sample(
            time: kf.keyTimes[i] * a.durSeconds * fr,
            value: kf.values[i].trim() == 'none' ? 0.0 : 100.0,
          ),
      ],
      isStep: true,
    );
  }

  factory _Track.fromOpacity(SvgAnimate a, double fr) {
    final kf = a.keyframes;
    return _Track(
      samples: [
        for (var i = 0; i < kf.values.length; i++)
          _Sample(
            time: kf.keyTimes[i] * a.durSeconds * fr,
            value: (double.tryParse(kf.values[i].trim()) ?? 0) * 100.0,
          ),
      ],
      isStep: kf.calcMode == SvgAnimationCalcMode.discrete,
    );
  }

  double sample(double t) {
    if (samples.isEmpty) return 100.0;
    if (t <= samples.first.time) return samples.first.value;
    if (t >= samples.last.time) return samples.last.value;
    if (isStep) {
      var v = samples.first.value;
      for (final k in samples) {
        if (k.time <= t) {
          v = k.value;
        } else {
          break;
        }
      }
      return v;
    }
    for (var i = 0; i + 1 < samples.length; i++) {
      final a = samples[i];
      final b = samples[i + 1];
      if (t >= a.time && t <= b.time) {
        final alpha =
            (b.time == a.time) ? 0.0 : (t - a.time) / (b.time - a.time);
        return a.value + (b.value - a.value) * alpha;
      }
    }
    return samples.last.value;
  }

  double sampleJustBefore(double t) {
    if (!isStep) return sample(t);
    if (samples.isEmpty) return 100.0;
    if (t <= samples.first.time) return samples.first.value;
    var v = samples.first.value;
    for (final k in samples) {
      if (k.time < t) {
        v = k.value;
      } else {
        break;
      }
    }
    return v;
  }
}

class _Sample {
  const _Sample({required this.time, required this.value});
  final double time;
  final double value;
}
