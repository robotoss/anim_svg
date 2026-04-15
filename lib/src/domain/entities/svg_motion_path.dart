import 'package:meta/meta.dart';

/// CSS Motion Path attached to a node via inline `style` (CSS Motion Path
/// Module Level 1 — `offset-path`, `offset-rotate`).
///
/// The associated animation of [offset-distance] drives the node along
/// [pathData]; [rotate] controls whether the node also rotates to match the
/// path tangent at each sampled point.
///
/// Concrete translate/rotate keyframes are produced later by
/// `MotionPathResolver`, which samples the path once the `SvgDocument` is
/// available (the CSS parser cannot see geometry on the node).
@immutable
class SvgMotionPath {
  const SvgMotionPath({
    required this.pathData,
    this.rotate = const SvgMotionRotate.auto(),
  });

  /// Raw SVG path `d` string as declared inside `offset-path: path('...')`.
  /// Quotes stripped; whitespace preserved.
  final String pathData;

  final SvgMotionRotate rotate;
}

/// `offset-rotate` value. `auto` → follow path tangent; `reverse` → tangent
/// flipped 180°; `fixed(deg)` → constant angle (tangent ignored, e.g.
/// `offset-rotate: 0deg` keeps the sprite upright).
@immutable
class SvgMotionRotate {
  const SvgMotionRotate.auto()
      : kind = SvgMotionRotateKind.auto,
        angleDeg = 0;
  const SvgMotionRotate.reverse()
      : kind = SvgMotionRotateKind.reverse,
        angleDeg = 0;
  const SvgMotionRotate.fixed(this.angleDeg)
      : kind = SvgMotionRotateKind.fixed;

  final SvgMotionRotateKind kind;
  final double angleDeg;
}

enum SvgMotionRotateKind { auto, reverse, fixed }
