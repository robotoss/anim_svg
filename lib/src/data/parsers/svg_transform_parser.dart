import 'dart:math' as math;

import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_transform.dart';

class SvgTransformParser {
  const SvgTransformParser();

  /// Parses an SVG `transform` attribute string like
  /// `translate(10 20)scale(.5)rotate(45 10 20)`
  /// into a list of [SvgStaticTransform] in order of application.
  ///
  /// Unknown transform functions (e.g. `skewX`) are logged as warnings and
  /// skipped, so the rest of the transform chain still applies.
  List<SvgStaticTransform> parse(String? raw, {AnimSvgLogger? logger}) {
    final log = logger ?? SilentLogger();
    if (raw == null || raw.trim().isEmpty) return const [];

    final result = <SvgStaticTransform>[];
    final re = RegExp(r'(\w+)\s*\(([^)]*)\)');
    for (final m in re.allMatches(raw)) {
      final name = m.group(1)!;
      final argsRaw = m.group(2)!;
      final args = _tokenizeNumbers(argsRaw);

      switch (name) {
        case 'translate':
          result.add(SvgStaticTransform(
            kind: SvgTransformKind.translate,
            values: args.length == 1 ? [args[0], 0] : [args[0], args[1]],
          ));
        case 'scale':
          result.add(SvgStaticTransform(
            kind: SvgTransformKind.scale,
            values: args.length == 1 ? [args[0], args[0]] : [args[0], args[1]],
          ));
        case 'rotate':
          result.add(SvgStaticTransform(
            kind: SvgTransformKind.rotate,
            values: args.length == 1
                ? [args[0], 0, 0]
                : [args[0], args[1], args[2]],
          ));
        case 'matrix':
          if (args.length != 6) {
            log.warn('parse.transform', 'skipping matrix() with wrong arity',
                fields: {'got': args.length, 'expected': 6});
            continue;
          }
          // Decompose matrix(a b c d e f) into translate + rotate + scale
          // (TRS). Lottie has no matrix; its ks.{p,r,s} applies as T·R·S.
          // Order the list so that when folded (translates summed, scales
          // multiplied, rotations summed) the result is equivalent.
          result.addAll(_decomposeMatrix(args));
        default:
          log.warn('parse.transform', 'skipping unsupported transform function',
              fields: {'fn': name});
      }
    }
    return result;
  }

  /// Tokenizes a compact SVG-style number list, where `-` and `+` inside the
  /// list act as both sign AND delimiter (e.g. `1.01-2-3` = `[1.01, -2, -3]`,
  /// `1.2e-3-4.5` = `[0.0012, -4.5]`). SVG minifiers strip whitespace around
  /// signs, so naive whitespace/comma splitting fails.
  static final _numberRe =
      RegExp(r'[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?');

  List<double> _tokenizeNumbers(String raw) {
    return _numberRe
        .allMatches(raw)
        .map((m) => double.parse(m.group(0)!))
        .toList();
  }

  /// Decomposes an SVG `matrix(a b c d e f)` into equivalent
  /// `translate(e,f) · rotate(θ) · scale(sx, sy)`.
  ///
  /// For pure TRS matrices this is exact. When the matrix includes shear
  /// (|b| ≠ |c|, as emitted by After Effects exports using skewed isometric
  /// projections), we still recover `sx`, `rot`, `tx`, `ty` correctly and
  /// derive `sy` from the determinant so area and orientation are preserved;
  /// the shear component is silently dropped (Lottie has no representation
  /// for it). This is strictly better than the previous
  /// `sy = sqrt(c²+d²)` formula, which over-estimated `sy` on sheared
  /// matrices and produced visibly wrong scale/position on affected nodes.
  List<SvgStaticTransform> _decomposeMatrix(List<double> m) {
    final a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5];
    final sx = math.sqrt(a * a + b * b);
    final sy = sx.abs() < 1e-9 ? 0.0 : (a * d - b * c) / sx;
    final rotRad = math.atan2(b, a);
    final rotDeg = rotRad * 180 / math.pi;
    return [
      SvgStaticTransform(
        kind: SvgTransformKind.translate,
        values: [e, f],
      ),
      SvgStaticTransform(
        kind: SvgTransformKind.rotate,
        values: [rotDeg, 0, 0],
      ),
      SvgStaticTransform(
        kind: SvgTransformKind.scale,
        values: [sx, sy],
      ),
    ];
  }
}
