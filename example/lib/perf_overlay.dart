import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class PerfOverlay extends StatefulWidget {
  const PerfOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<PerfOverlay> createState() => _PerfOverlayState();
}

class _PerfOverlayState extends State<PerfOverlay> {
  static const int _windowSize = 120;
  static const Duration _logInterval = Duration(seconds: 10);

  final List<double> _frameMs = <double>[];
  Stopwatch? _logTimer;

  double _p50 = 0;
  double _p95 = 0;
  double _p99 = 0;

  @override
  void initState() {
    super.initState();
    _logTimer = Stopwatch()..start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!mounted) return;
    for (final t in timings) {
      final totalUs = t.totalSpan.inMicroseconds;
      _frameMs.add(totalUs / 1000.0);
      if (_frameMs.length > _windowSize) {
        _frameMs.removeRange(0, _frameMs.length - _windowSize);
      }
    }
    final sorted = List<double>.from(_frameMs)..sort();
    final p50 = _percentile(sorted, 0.50);
    final p95 = _percentile(sorted, 0.95);
    final p99 = _percentile(sorted, 0.99);
    setState(() {
      _p50 = p50;
      _p95 = p95;
      _p99 = p99;
    });
    if (_logTimer != null && _logTimer!.elapsed >= _logInterval) {
      _logTimer!.reset();
      developer.log(
        'p50=${p50.toStringAsFixed(2)}ms '
        'p95=${p95.toStringAsFixed(2)}ms '
        'p99=${p99.toStringAsFixed(2)}ms '
        'samples=${sorted.length}',
        name: 'anim_svg-perf',
      );
    }
  }

  double _percentile(List<double> sortedAsc, double q) {
    if (sortedAsc.isEmpty) return 0;
    final i = (sortedAsc.length * q).floor().clamp(0, sortedAsc.length - 1);
    return sortedAsc[i];
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode && !kProfileMode) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 40,
          right: 8,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'p50 ${_p50.toStringAsFixed(1)}\n'
                'p95 ${_p95.toStringAsFixed(1)}\n'
                'p99 ${_p99.toStringAsFixed(1)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  height: 1.2,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
