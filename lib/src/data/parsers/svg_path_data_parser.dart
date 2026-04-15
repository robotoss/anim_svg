import 'dart:math' as math;

import '../../core/logger.dart';

/// A sequence of cubic bezier segments describing a closed or open contour.
/// Lottie's `sh` (ty:"sh") shape uses the same triplet: `v` (vertices),
/// `i` (in-tangents, relative to vertex), `o` (out-tangents, relative to
/// vertex), and a `c` flag for closed contours.
class CubicContour {
  CubicContour({
    required this.vertices,
    required this.inTangents,
    required this.outTangents,
    required this.closed,
  });

  final List<List<double>> vertices;
  final List<List<double>> inTangents;
  final List<List<double>> outTangents;
  final bool closed;
}

/// Minimal SVG path `d` parser that normalises every command into cubic
/// bezier segments for Lottie emission.
///
/// Supported commands (absolute and relative):
/// - `M` / `m` — move to (start of new contour)
/// - `L` / `l` — line to
/// - `H` / `h` — horizontal line to
/// - `V` / `v` — vertical line to
/// - `C` / `c` — cubic bezier
/// - `S` / `s` — smooth cubic (reflect previous out-tangent)
/// - `Q` / `q` — quadratic bezier (converted to cubic)
/// - `T` / `t` — smooth quadratic
/// - `A` / `a` — elliptical arc (approximated as cubic bezier segments)
/// - `Z` / `z` — close
class SvgPathDataParser {
  const SvgPathDataParser();

  /// Parses the `d` attribute into a flat list of [CubicContour]s, one per
  /// sub-path. An empty/invalid input returns `const []` and logs a warning.
  ///
  /// When [dropClosingDuplicate] is true (default), a coincident final vertex
  /// on a closed contour is trimmed — Lottie's static `sh` prefers the
  /// triplet without an explicit close-vertex. Set to false for animated
  /// `attributeName="d"` frames where the trim would yield inconsistent
  /// vertex counts across keyframes (numeric endpoint "close enough" to
  /// start in some frames but not others).
  List<CubicContour> parse(String d,
      {AnimSvgLogger? logger, bool dropClosingDuplicate = true}) {
    final log = logger ?? SilentLogger();
    final tokens = _tokenize(d);
    if (tokens.isEmpty) return const [];

    final contours = <CubicContour>[];
    var verts = <List<double>>[];
    var ins = <List<double>>[];
    var outs = <List<double>>[];

    double x = 0, y = 0;
    double startX = 0, startY = 0;
    double? lastCubicCtrlX, lastCubicCtrlY;
    double? lastQuadCtrlX, lastQuadCtrlY;

    void closeContour({required bool closed}) {
      if (verts.isEmpty) return;
      // If closed and the last vertex coincides with the first, drop the
      // duplicate (Lottie prefers the triplet without explicit close-vertex).
      if (dropClosingDuplicate && closed && verts.length > 1) {
        final last = verts.last;
        final first = verts.first;
        if ((last[0] - first[0]).abs() < 1e-6 &&
            (last[1] - first[1]).abs() < 1e-6) {
          verts = verts.sublist(0, verts.length - 1);
          ins = ins.sublist(0, ins.length - 1);
          outs = outs.sublist(0, outs.length - 1);
        }
      }
      contours.add(CubicContour(
        vertices: verts,
        inTangents: ins,
        outTangents: outs,
        closed: closed,
      ));
      verts = <List<double>>[];
      ins = <List<double>>[];
      outs = <List<double>>[];
    }

    void addVertex(double vx, double vy) {
      verts.add([vx, vy]);
      ins.add([0, 0]);
      outs.add([0, 0]);
    }

    void setOutTangent(double cx, double cy) {
      if (outs.isEmpty) return;
      final v = verts.last;
      outs[outs.length - 1] = [cx - v[0], cy - v[1]];
    }

    void setInTangent(double cx, double cy) {
      if (ins.isEmpty) return;
      final v = verts.last;
      ins[ins.length - 1] = [cx - v[0], cy - v[1]];
    }

    var i = 0;
    while (i < tokens.length) {
      final cmd = tokens[i];
      if (cmd is! String) {
        log.warn('parse.path', 'unexpected number without command',
            fields: {'at': i, 'value': cmd});
        i++;
        continue;
      }
      final isRel = cmd.toLowerCase() == cmd;
      final upper = cmd.toUpperCase();

      double next() {
        i++;
        if (i >= tokens.length || tokens[i] is String) {
          log.warn('parse.path', 'missing number after command',
              fields: {'cmd': cmd});
          return 0;
        }
        return (tokens[i] as double);
      }

      switch (upper) {
        case 'M':
          if (verts.isNotEmpty) closeContour(closed: false);
          final nx = isRel ? x + next() : next();
          final ny = isRel ? y + next() : next();
          x = nx;
          y = ny;
          startX = x;
          startY = y;
          addVertex(x, y);
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          // Subsequent coord pairs after M are implicit L (or l if relative).
          while (i + 1 < tokens.length &&
              tokens[i + 1] is double &&
              (i + 2 >= tokens.length || tokens[i + 2] is double)) {
            final lx = isRel ? x + next() : next();
            final ly = isRel ? y + next() : next();
            x = lx;
            y = ly;
            addVertex(x, y);
          }
          i++;
        case 'L':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final lx = isRel ? x + next() : next();
            final ly = isRel ? y + next() : next();
            x = lx;
            y = ly;
            addVertex(x, y);
          }
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        case 'H':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final nx = isRel ? x + next() : next();
            x = nx;
            addVertex(x, y);
          }
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        case 'V':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final ny = isRel ? y + next() : next();
            y = ny;
            addVertex(x, y);
          }
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        case 'C':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final x1 = isRel ? x + next() : next();
            final y1 = isRel ? y + next() : next();
            final x2 = isRel ? x + next() : next();
            final y2 = isRel ? y + next() : next();
            final ex = isRel ? x + next() : next();
            final ey = isRel ? y + next() : next();
            setOutTangent(x1, y1);
            addVertex(ex, ey);
            setInTangent(x2, y2);
            x = ex;
            y = ey;
            lastCubicCtrlX = x2;
            lastCubicCtrlY = y2;
          }
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        case 'S':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final rx = lastCubicCtrlX != null
                ? 2 * x - lastCubicCtrlX
                : x;
            final ry = lastCubicCtrlY != null
                ? 2 * y - lastCubicCtrlY
                : y;
            final x2 = isRel ? x + next() : next();
            final y2 = isRel ? y + next() : next();
            final ex = isRel ? x + next() : next();
            final ey = isRel ? y + next() : next();
            setOutTangent(rx, ry);
            addVertex(ex, ey);
            setInTangent(x2, y2);
            x = ex;
            y = ey;
            lastCubicCtrlX = x2;
            lastCubicCtrlY = y2;
          }
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        case 'Q':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final qx = isRel ? x + next() : next();
            final qy = isRel ? y + next() : next();
            final ex = isRel ? x + next() : next();
            final ey = isRel ? y + next() : next();
            // Convert quad Q(p0, q, p1) to cubic Q(p0, p0 + 2/3(q-p0), p1 + 2/3(q-p1), p1).
            final c1x = x + 2 / 3 * (qx - x);
            final c1y = y + 2 / 3 * (qy - y);
            final c2x = ex + 2 / 3 * (qx - ex);
            final c2y = ey + 2 / 3 * (qy - ey);
            setOutTangent(c1x, c1y);
            addVertex(ex, ey);
            setInTangent(c2x, c2y);
            x = ex;
            y = ey;
            lastQuadCtrlX = qx;
            lastQuadCtrlY = qy;
          }
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          i++;
        case 'T':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final qx = lastQuadCtrlX != null
                ? 2 * x - lastQuadCtrlX
                : x;
            final qy = lastQuadCtrlY != null
                ? 2 * y - lastQuadCtrlY
                : y;
            final ex = isRel ? x + next() : next();
            final ey = isRel ? y + next() : next();
            final c1x = x + 2 / 3 * (qx - x);
            final c1y = y + 2 / 3 * (qy - y);
            final c2x = ex + 2 / 3 * (qx - ex);
            final c2y = ey + 2 / 3 * (qy - ey);
            setOutTangent(c1x, c1y);
            addVertex(ex, ey);
            setInTangent(c2x, c2y);
            x = ex;
            y = ey;
            lastQuadCtrlX = qx;
            lastQuadCtrlY = qy;
          }
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          i++;
        case 'A':
          while (i + 1 < tokens.length && tokens[i + 1] is double) {
            final rx = next();
            final ry = next();
            final rot = next();
            final largeArc = next() != 0;
            final sweep = next() != 0;
            final ex = isRel ? x + next() : next();
            final ey = isRel ? y + next() : next();
            _emitArc(
              x, y, ex, ey, rx, ry, rot, largeArc, sweep,
              addVertex, setOutTangent, setInTangent,
            );
            x = ex;
            y = ey;
          }
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        case 'Z':
          x = startX;
          y = startY;
          closeContour(closed: true);
          lastCubicCtrlX = null;
          lastCubicCtrlY = null;
          lastQuadCtrlX = null;
          lastQuadCtrlY = null;
          i++;
        default:
          log.warn('parse.path', 'unknown path command',
              fields: {'cmd': cmd});
          i++;
      }
    }

    if (verts.isNotEmpty) closeContour(closed: false);
    return contours;
  }

  /// Converts an SVG elliptical arc segment into a sequence of cubic bezier
  /// segments and emits them through the provided tangent/vertex callbacks.
  ///
  /// Follows W3C SVG 1.1 Appendix F.6: endpoint → center parameterisation,
  /// radii correction, then splits the sweep into ≤ 90° sub-arcs and
  /// approximates each with a cubic using the `4/3 * tan(θ/4)` constant.
  void _emitArc(
    double x1, double y1, double x2, double y2,
    double rxIn, double ryIn, double rotDeg,
    bool largeArc, bool sweep,
    void Function(double, double) addVertex,
    void Function(double, double) setOut,
    void Function(double, double) setIn,
  ) {
    if (x1 == x2 && y1 == y2) return;
    var rx = rxIn.abs();
    var ry = ryIn.abs();
    if (rx == 0 || ry == 0) {
      addVertex(x2, y2);
      return;
    }
    final phi = rotDeg * math.pi / 180.0;
    final cosPhi = math.cos(phi);
    final sinPhi = math.sin(phi);

    // Step 1: translated/rotated endpoint midpoint.
    final dx = (x1 - x2) / 2.0;
    final dy = (y1 - y2) / 2.0;
    final x1p = cosPhi * dx + sinPhi * dy;
    final y1p = -sinPhi * dx + cosPhi * dy;

    // Step 2: radii correction.
    final lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
      final s = math.sqrt(lambda);
      rx *= s;
      ry *= s;
    }

    // Step 3: centre prime.
    final rx2 = rx * rx;
    final ry2 = ry * ry;
    final x1p2 = x1p * x1p;
    final y1p2 = y1p * y1p;
    final denom = rx2 * y1p2 + ry2 * x1p2;
    final numer = rx2 * ry2 - denom;
    final factor = math.sqrt(math.max(0, numer / denom));
    final sign = largeArc == sweep ? -1.0 : 1.0;
    final cxp = sign * factor * (rx * y1p / ry);
    final cyp = sign * factor * (-ry * x1p / rx);

    // Step 4: actual centre.
    final cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2.0;
    final cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2.0;

    // Step 5: start angle and sweep delta on the unit ellipse.
    double angle(double ux, double uy, double vx, double vy) {
      final dot = ux * vx + uy * vy;
      final len = math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
      final c = (dot / len).clamp(-1.0, 1.0);
      final sgn = (ux * vy - uy * vx) < 0 ? -1.0 : 1.0;
      return sgn * math.acos(c);
    }

    final ux = (x1p - cxp) / rx;
    final uy = (y1p - cyp) / ry;
    final vx = (-x1p - cxp) / rx;
    final vy = (-y1p - cyp) / ry;
    var theta1 = angle(1, 0, ux, uy);
    var delta = angle(ux, uy, vx, vy);
    if (!sweep && delta > 0) delta -= 2 * math.pi;
    if (sweep && delta < 0) delta += 2 * math.pi;

    // Step 6: split into ≤ 90° segments and emit a cubic per segment.
    final segCount = math.max(1, (delta.abs() / (math.pi / 2)).ceil());
    final segAngle = delta / segCount;
    final t = 4.0 / 3.0 * math.tan(segAngle / 4.0);

    for (var k = 0; k < segCount; k++) {
      final a1 = theta1 + k * segAngle;
      final a2 = a1 + segAngle;
      final cosA1 = math.cos(a1), sinA1 = math.sin(a1);
      final cosA2 = math.cos(a2), sinA2 = math.sin(a2);

      // Control points on the unit-radius ellipse (before scale+rotate+translate).
      final p1x = cosA1 - t * sinA1;
      final p1y = sinA1 + t * cosA1;
      final p2x = cosA2 + t * sinA2;
      final p2y = sinA2 - t * cosA2;
      final p3x = cosA2;
      final p3y = sinA2;

      List<double> project(double ex, double ey) {
        final sx = ex * rx;
        final sy = ey * ry;
        return [
          cosPhi * sx - sinPhi * sy + cx,
          sinPhi * sx + cosPhi * sy + cy,
        ];
      }

      final c1 = project(p1x, p1y);
      final c2 = project(p2x, p2y);
      final p3 = project(p3x, p3y);

      setOut(c1[0], c1[1]);
      addVertex(p3[0], p3[1]);
      setIn(c2[0], c2[1]);
    }
  }

  /// Returns a list of tokens that are either command letters (`String`)
  /// or numeric arguments (`double`).
  List<Object> _tokenize(String d) {
    final tokens = <Object>[];
    final re = RegExp(
        r'[MmLlHhVvCcSsQqTtAaZz]|[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?');
    for (final m in re.allMatches(d)) {
      final s = m.group(0)!;
      final first = s.codeUnitAt(0);
      final isAlpha = (first >= 0x41 && first <= 0x5A) ||
          (first >= 0x61 && first <= 0x7A);
      if (isAlpha) {
        tokens.add(s);
      } else {
        final n = double.tryParse(s);
        if (n != null && !n.isNaN && !n.isInfinite) tokens.add(n);
      }
    }
    return tokens;
  }
}

/// Discrete approximation of a circle/ellipse by 4 cubic bezier segments.
/// Magic constant `0.5522847498...` = `4/3 * tan(π/8)`.
CubicContour ellipseContour(double cx, double cy, double rx, double ry) {
  const k = 0.5522847498307936;
  final vx = [
    [cx, cy - ry],
    [cx + rx, cy],
    [cx, cy + ry],
    [cx - rx, cy],
  ];
  final outT = <List<double>>[
    [rx * k, 0],
    [0, ry * k],
    [-rx * k, 0],
    [0, -ry * k],
  ];
  final inT = <List<double>>[
    [-rx * k, 0],
    [0, -ry * k],
    [rx * k, 0],
    [0, ry * k],
  ];
  return CubicContour(
      vertices: vx, inTangents: inT, outTangents: outT, closed: true);
}

/// Rectangle with optional rounded corners. If `rx`/`ry` are 0, emits 4
/// straight vertices; otherwise rounds each corner with a quarter-ellipse.
CubicContour rectContour(
    double x, double y, double w, double h, double rx, double ry) {
  if (rx <= 0 && ry <= 0) {
    return CubicContour(
      vertices: [
        [x, y],
        [x + w, y],
        [x + w, y + h],
        [x, y + h],
      ],
      inTangents: List.filled(4, [0, 0]),
      outTangents: List.filled(4, [0, 0]),
      closed: true,
    );
  }
  // Clamp to half-dim so radii don't exceed the rect.
  rx = math.min(rx, w / 2);
  ry = math.min(ry, h / 2);
  const k = 0.5522847498307936;
  // 8 vertices: two per corner (in+out). Order: TL-end, TR-start, TR-end,
  // BR-start, BR-end, BL-start, BL-end, TL-start.
  final vertices = <List<double>>[
    [x + rx, y],
    [x + w - rx, y],
    [x + w, y + ry],
    [x + w, y + h - ry],
    [x + w - rx, y + h],
    [x + rx, y + h],
    [x, y + h - ry],
    [x, y + ry],
  ];
  final inT = <List<double>>[
    [0, 0],
    [0, 0],
    [0, -ry * k],
    [0, 0],
    [rx * k, 0],
    [0, 0],
    [0, ry * k],
    [0, 0],
  ];
  final outT = <List<double>>[
    [0, 0],
    [rx * k, 0],
    [0, 0],
    [0, ry * k],
    [0, 0],
    [-rx * k, 0],
    [0, 0],
    [0, -ry * k],
  ];
  return CubicContour(
      vertices: vertices, inTangents: inT, outTangents: outT, closed: true);
}

/// Polyline/polygon vertex list → contour with zero tangents.
CubicContour polyContour(List<List<double>> points, {required bool closed}) {
  return CubicContour(
    vertices: points,
    inTangents: List.generate(points.length, (_) => [0.0, 0.0]),
    outTangents: List.generate(points.length, (_) => [0.0, 0.0]),
    closed: closed,
  );
}
