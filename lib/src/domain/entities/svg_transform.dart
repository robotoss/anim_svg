import 'package:meta/meta.dart';

import 'svg_animation.dart';

@immutable
class SvgStaticTransform {
  const SvgStaticTransform({
    required this.kind,
    required this.values,
  });

  final SvgTransformKind kind;

  /// translate: [x, y]; scale: [sx, sy]; rotate: [deg, cx, cy]
  final List<double> values;
}
