import '../../core/logger.dart';
import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_document.dart';
import '../parsers/svg_path_data_parser.dart';
import 'keyspline_mapper.dart';

/// Converts `SvgShape` geometry and fill into a list of Lottie shape items
/// (one geometry item + one fill item). Transforms are handled by the
/// caller (image-layer logic already composes static transforms into a
/// layer-level `ks` transform).
class ShapeMapper {
  const ShapeMapper({
    SvgPathDataParser? pathParser,
    double frameRate = 60,
    KeySplineMapper splines = const KeySplineMapper(),
  })  : _pathParser = pathParser ?? const SvgPathDataParser(),
        _frameRate = frameRate,
        _splines = splines;

  final SvgPathDataParser _pathParser;
  final double _frameRate;
  final KeySplineMapper _splines;

  List<LottieShapeItem> map(
    SvgShape node, {
    Map<String, SvgGradient> gradients = const {},
    AnimSvgLogger? logger,
  }) {
    final log = logger ?? SilentLogger();
    final geometry = _buildGeometry(node, log);
    if (geometry.isEmpty) return const [];

    final fill = _buildFillItem(node, gradients, log);
    final stroke = _buildStrokeItem(node, log);
    final trim = _buildTrimPathItem(node, log);

    // Item order inside the shape group follows Lottie conventions:
    //   path(s) → fill → stroke → trim paths.
    // Trim paths must come AFTER the geometry/fill/stroke items they modify;
    // every preceding path in the group is trimmed to [start, end].
    return [
      ...geometry,
      ?fill,
      ?stroke,
      ?trim,
    ];
  }

  /// Resolves the fill item (solid, gradient, or grey fallback) for [node],
  /// or `null` when `fill="none"` / unrecognised-value-with-no-colour.
  LottieShapeItem? _buildFillItem(
    SvgShape node,
    Map<String, SvgGradient> gradients,
    AnimSvgLogger log,
  ) {
    final fillRaw = node.fill.trim();
    final urlId = _gradientHrefId(fillRaw);
    if (urlId != null) {
      final grad = gradients[urlId];
      if (grad != null) {
        final gf = _buildGradientFill(grad, node, log);
        if (gf != null) return gf;
      } else {
        log.warn('map.shape', 'gradient id not found → grey fallback',
            fields: {'fill': fillRaw});
      }
      final opacity = node.fillOpacity * node.opacity * 100.0;
      return LottieShapeFill(
          color: const [0.5, 0.5, 0.5, 1], opacity: opacity);
    }

    final fillColor = _parseColor(fillRaw, log);
    if (fillColor == null) {
      log.debug('map.shape', 'shape has no fill; skipping fill emission',
          fields: {'kind': node.kind.name, 'fillRaw': node.fill});
      return null;
    }
    // Lottie's `c.k` array expects 4 elements [r,g,b,a]; thorvg and lottie-web
    // renderers treat alpha from the `o` (opacity) scalar as authoritative and
    // ignore the 4th channel, so fold rgba()/hsla() alpha into fillOpacity
    // while keeping the color tuple 4-element with alpha=1.
    final colorAlpha = fillColor.length >= 4 ? fillColor[3] : 1.0;
    final rgba = <double>[fillColor[0], fillColor[1], fillColor[2], 1.0];
    final fillOpacity = node.fillOpacity * node.opacity * colorAlpha * 100.0;
    return LottieShapeFill(color: rgba, opacity: fillOpacity);
  }

  LottieShapeStroke? _buildStrokeItem(SvgShape node, AnimSvgLogger log) {
    final raw = node.stroke?.trim();
    if (raw == null || raw.isEmpty || raw.toLowerCase() == 'none') return null;
    // Gradient strokes (`url(#id)`) aren't supported yet — fall back to grey
    // so the stroke is still visible instead of silently dropped.
    List<double>? rgba;
    if (raw.toLowerCase().startsWith('url(')) {
      log.warn('map.shape',
          'gradient stroke not yet supported → fallback grey',
          fields: {'stroke': raw});
      rgba = const [0.5, 0.5, 0.5, 1];
    } else {
      rgba = _parseColor(raw, log);
    }
    if (rgba == null) return null;
    final colorAlpha = rgba.length >= 4 ? rgba[3] : 1.0;
    final color = <double>[rgba[0], rgba[1], rgba[2], 1.0];
    final opacity =
        node.strokeOpacity * node.opacity * colorAlpha * 100.0;
    return LottieShapeStroke(
      color: color,
      opacity: opacity,
      width: node.strokeWidth > 0 ? node.strokeWidth : 1.0,
      lineCap: _mapLineCap(node.strokeLinecap),
      lineJoin: _mapLineJoin(node.strokeLinejoin),
    );
  }

  int _mapLineCap(String? cap) => switch (cap?.trim().toLowerCase()) {
        'round' => 2,
        'square' => 3,
        _ => 1,
      };

  int _mapLineJoin(String? join) => switch (join?.trim().toLowerCase()) {
        'round' => 2,
        'bevel' => 3,
        _ => 1,
      };

  /// Converts an animated `stroke-dashoffset` track + static `stroke-dasharray`
  /// into a Lottie Trim Paths modifier. Supports the "draw-on" pattern
  /// (`stroke-dasharray=L, stroke-dashoffset: L → 0`) used by SVGator / AE /
  /// Figma exports; dash *patterns* (multi-value dasharray) aren't modelled.
  LottieShapeTrimPath? _buildTrimPathItem(SvgShape node, AnimSvgLogger log) {
    if (node.stroke == null || node.stroke!.trim().toLowerCase() == 'none') {
      return null;
    }
    final anim = node.animations
        .whereType<SvgAnimate>()
        .where((a) => a.attributeName == 'stroke-dashoffset')
        .firstOrNull;
    if (anim == null) return null;
    if (anim.durSeconds <= 0) return null;

    // Path length (L). Prefer the static `stroke-dasharray` (the single-value
    // form exporters use for draw-on); fall back to the largest dashoffset
    // keyframe value so the animation still normalises sensibly.
    final parsedVals = anim.keyframes.values
        .map((v) => double.tryParse(v.trim()))
        .toList();
    final dashFromArray = _firstNumeric(node.strokeDasharray);
    var length = (dashFromArray != null && dashFromArray > 0)
        ? dashFromArray
        : parsedVals
            .whereType<double>()
            .fold<double>(0, (p, v) => v.abs() > p ? v.abs() : p);
    if (length <= 0) {
      log.warn('map.shape',
          'stroke-dashoffset animated but no path length; trim skipped',
          fields: {'id': node.id ?? ''});
      return null;
    }

    final keyTimes = anim.keyframes.keyTimes;
    final kfs = <LottieScalarKeyframe>[];
    for (var i = 0; i < parsedVals.length; i++) {
      final v = parsedVals[i];
      if (v == null) {
        log.warn('map.shape',
            'stroke-dashoffset keyframe not numeric → trim skipped',
            fields: {'id': node.id ?? '', 'index': i});
        return null;
      }
      final endPct = (1.0 - (v / length)).clamp(0.0, 1.0) * 100.0;
      final time = keyTimes[i] * anim.durSeconds * _frameRate;
      BezierHandle? inH;
      BezierHandle? outH;
      if (i == 0) {
        outH = _splines.segment(anim.keyframes, 0).$1;
      } else {
        inH = _splines.segment(anim.keyframes, i - 1).$2;
        if (i < parsedVals.length - 1) {
          outH = _splines.segment(anim.keyframes, i).$1;
        }
      }
      kfs.add(LottieScalarKeyframe(
        time: time,
        start: endPct,
        hold: _splines.hold(anim.keyframes),
        bezierIn: inH,
        bezierOut: outH,
      ));
    }

    return LottieShapeTrimPath(
      start: const LottieScalarStatic(0),
      end: LottieScalarAnimated(kfs),
      offset: const LottieScalarStatic(0),
    );
  }

  /// Returns the first numeric token from a space/comma-separated list, or
  /// `null` when none parse. Used for single-value `stroke-dasharray`.
  double? _firstNumeric(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    if (t.isEmpty) return null;
    for (final tok in t.split(RegExp(r'[ ,]+'))) {
      final n = double.tryParse(tok);
      if (n != null) return n;
    }
    return null;
  }

  String? _gradientHrefId(String fill) {
    final t = fill.trim();
    if (!t.toLowerCase().startsWith('url(')) return null;
    final open = t.indexOf('(');
    final close = t.lastIndexOf(')');
    if (open < 0 || close < 0) return null;
    var body = t.substring(open + 1, close).trim();
    if (body.startsWith('"') || body.startsWith("'")) {
      body = body.substring(1, body.length - 1);
    }
    if (body.startsWith('#')) body = body.substring(1);
    return body.isEmpty ? null : body;
  }

  LottieShapeGradientFill? _buildGradientFill(
      SvgGradient grad, SvgShape node, AnimSvgLogger log) {
    if (grad.stops.isEmpty) {
      log.warn('map.shape', 'gradient has no stops → fallback',
          fields: {'id': grad.id});
      return null;
    }
    final (startPt, endPt) = _gradientEndpoints(grad, node, log);
    final colorCount = grad.stops.length;

    final anyAnimated = grad.stops.any((s) => s.animations.isNotEmpty);
    final LottieGradientStops stops;
    if (!anyAnimated) {
      stops = LottieGradientStopsStatic(
          _flatStops(grad.stops, grad.stops.map((s) => s.offset).toList(), log));
    } else {
      stops = _animatedStops(grad.stops, log);
    }

    final opacity = node.fillOpacity * node.opacity * 100.0;
    return LottieShapeGradientFill(
      kind: grad.kind == SvgGradientKind.radial
          ? LottieGradientKind.radial
          : LottieGradientKind.linear,
      colorStopCount: colorCount,
      startPoint: startPt,
      endPoint: endPt,
      stops: stops,
      opacity: opacity,
    );
  }

  (List<double>, List<double>) _gradientEndpoints(
      SvgGradient grad, SvgShape node, AnimSvgLogger log) {
    List<double> start;
    List<double> end;
    if (grad.units == SvgGradientUnits.objectBoundingBox) {
      final bb = _shapeBoundingBox(node);
      double mapX(double u) => bb.x + u * bb.w;
      double mapY(double v) => bb.y + v * bb.h;
      if (grad.kind == SvgGradientKind.radial) {
        start = [mapX(grad.cx), mapY(grad.cy)];
        end = [mapX(grad.cx + grad.r), mapY(grad.cy)];
      } else {
        start = [mapX(grad.x1), mapY(grad.y1)];
        end = [mapX(grad.x2), mapY(grad.y2)];
      }
    } else if (grad.kind == SvgGradientKind.radial) {
      start = [grad.cx, grad.cy];
      end = [grad.cx + grad.r, grad.cy];
    } else {
      start = [grad.x1, grad.y1];
      end = [grad.x2, grad.y2];
    }
    final gt = grad.gradientTransform;
    if (gt != null && gt.length == 6) {
      start = _applyAffine(gt, start[0], start[1]);
      end = _applyAffine(gt, end[0], end[1]);
    }
    return (start, end);
  }

  /// Applies a flat 2D affine matrix `[a, b, c, d, e, f]` to a point.
  List<double> _applyAffine(List<double> m, double x, double y) {
    return [
      m[0] * x + m[2] * y + m[4],
      m[1] * x + m[3] * y + m[5],
    ];
  }

  _Bbox _shapeBoundingBox(SvgShape node) {
    switch (node.kind) {
      case SvgShapeKind.rect:
        return _Bbox(node.x, node.y, node.width, node.height);
      case SvgShapeKind.circle:
        return _Bbox(node.cx - node.r, node.cy - node.r, node.r * 2, node.r * 2);
      case SvgShapeKind.ellipse:
        return _Bbox(
            node.cx - node.rx, node.cy - node.ry, node.rx * 2, node.ry * 2);
      case SvgShapeKind.line:
        final minX = node.x1 < node.x2 ? node.x1 : node.x2;
        final minY = node.y1 < node.y2 ? node.y1 : node.y2;
        return _Bbox(
            minX, minY, (node.x2 - node.x1).abs(), (node.y2 - node.y1).abs());
      case SvgShapeKind.polyline:
      case SvgShapeKind.polygon:
      case SvgShapeKind.path:
        return const _Bbox(0, 0, 1, 1);
    }
  }

  List<double> _flatStops(
      List<SvgStop> stops, List<double> offsets, AnimSvgLogger log) {
    final colorPart = <double>[];
    final opacityPart = <double>[];
    var hasAlpha = false;
    for (var i = 0; i < stops.length; i++) {
      final s = stops[i];
      final off = offsets[i].clamp(0.0, 1.0);
      final rgba = _parseColor(s.color, log) ?? const [0, 0, 0, 1];
      colorPart.addAll([off, rgba[0], rgba[1], rgba[2]]);
      opacityPart.addAll([off, s.stopOpacity]);
      if ((s.stopOpacity - 1.0).abs() > 1e-6) hasAlpha = true;
    }
    return hasAlpha ? [...colorPart, ...opacityPart] : colorPart;
  }

  LottieGradientStopsAnimated _animatedStops(
      List<SvgStop> stops, AnimSvgLogger log) {
    // Take max duration across stop animations; collect a shared set of
    // sample times (0, each stop's own keyTimes, 1). For stops without
    // animation we hold their static offset across all samples.
    var dur = 0.0;
    final sampleTimes = <double>{0, 1};
    for (final s in stops) {
      for (final a in s.animations.whereType<SvgAnimate>()) {
        if (a.attributeName != 'offset') continue;
        if (a.durSeconds > dur) dur = a.durSeconds;
        sampleTimes.addAll(a.keyframes.keyTimes);
      }
    }
    if (dur <= 0) {
      // Fallback to static if durations are absent.
      return LottieGradientStopsAnimated([
        LottieGradientKeyframe(
          time: 0,
          values:
              _flatStops(stops, stops.map((s) => s.offset).toList(), log),
        ),
      ]);
    }
    final times = sampleTimes.toList()..sort();
    final kfs = <LottieGradientKeyframe>[];
    for (final t in times) {
      final offs = [
        for (final s in stops) _sampleStopOffset(s, t),
      ];
      kfs.add(LottieGradientKeyframe(
        time: t * dur * _frameRate,
        values: _flatStops(stops, offs, log),
      ));
    }
    return LottieGradientStopsAnimated(kfs);
  }

  double _sampleStopOffset(SvgStop s, double progress) {
    for (final a in s.animations.whereType<SvgAnimate>()) {
      if (a.attributeName != 'offset') continue;
      final kt = a.keyframes.keyTimes;
      final vals = a.keyframes.values
          .map((v) => double.tryParse(v.trim()) ?? s.offset)
          .toList();
      if (kt.isEmpty || vals.isEmpty) continue;
      if (progress <= kt.first) return vals.first;
      if (progress >= kt.last) return vals.last;
      for (var i = 0; i < kt.length - 1; i++) {
        if (progress >= kt[i] && progress <= kt[i + 1]) {
          final span = kt[i + 1] - kt[i];
          final alpha = span == 0 ? 0.0 : (progress - kt[i]) / span;
          return vals[i] + (vals[i + 1] - vals[i]) * alpha;
        }
      }
    }
    return s.offset;
  }

  List<LottieShapeItem> _buildGeometry(SvgShape node, AnimSvgLogger log) {
    switch (node.kind) {
      case SvgShapeKind.rect:
        return [
          LottieShapeGeometry(
            kind: LottieShapeKind.rect,
            rectPosition: [node.x + node.width / 2, node.y + node.height / 2],
            rectSize: [node.width, node.height],
            rectRoundness: node.rx > 0 ? node.rx : node.ry,
          ),
        ];
      case SvgShapeKind.circle:
        return [
          LottieShapeGeometry(
            kind: LottieShapeKind.ellipse,
            ellipsePosition: [node.cx, node.cy],
            ellipseSize: [node.r * 2, node.r * 2],
          ),
        ];
      case SvgShapeKind.ellipse:
        return [
          LottieShapeGeometry(
            kind: LottieShapeKind.ellipse,
            ellipsePosition: [node.cx, node.cy],
            ellipseSize: [node.rx * 2, node.ry * 2],
          ),
        ];
      case SvgShapeKind.line:
        return [
          LottieShapeGeometry(
            kind: LottieShapeKind.path,
            vertices: [
              [node.x1, node.y1],
              [node.x2, node.y2],
            ],
            inTangents: [[0, 0], [0, 0]],
            outTangents: [[0, 0], [0, 0]],
            closed: false,
          ),
        ];
      case SvgShapeKind.polyline:
      case SvgShapeKind.polygon:
        if (node.points.isEmpty) {
          log.warn('map.shape', 'polyline/polygon has no points',
              fields: {'kind': node.kind.name});
          return const [];
        }
        final contour = polyContour(node.points,
            closed: node.kind == SvgShapeKind.polygon);
        return [_contourToGeometry(contour)];
      case SvgShapeKind.path:
        final d = node.d;
        if (d == null || d.trim().isEmpty) {
          log.warn('map.shape', 'path has no d attribute',
              fields: {'id': node.id ?? ''});
          return const [];
        }
        final dAnim = node.animations
            .whereType<SvgAnimate>()
            .where((a) => a.attributeName == 'd')
            .firstOrNull;
        if (dAnim != null) {
          final animated = _buildAnimatedPath(node, dAnim, log);
          if (animated != null) return [animated];
        }
        final contours = _pathParser.parse(d, logger: log);
        if (contours.isEmpty) return const [];
        return contours.map(_contourToGeometry).toList();
    }
  }

  /// Builds an animated `sh` geometry from a `<animate attributeName="d">`
  /// node. Returns null when any keyframe fails to parse, topology mismatches
  /// between frames, or inputs are degenerate — the caller then falls back
  /// to the static path. Lottie requires every keyframe to share vertex count
  /// and closed flag; we bail out when they don't rather than rendering a
  /// corrupted shape.
  LottieShapeGeometry? _buildAnimatedPath(
      SvgShape node, SvgAnimate anim, AnimSvgLogger log) {
    final values = anim.keyframes.values;
    final keyTimes = anim.keyframes.keyTimes;
    if (values.length < 2 || keyTimes.length != values.length) {
      return null;
    }
    if (anim.durSeconds <= 0) return null;

    final contours = <CubicContour>[];
    var warnedMulti = false;
    for (var i = 0; i < values.length; i++) {
      // Disable the close-duplicate dedup: across keyframes the numeric
      // endpoint may coincide with the start in some frames but not others,
      // producing inconsistent vertex counts. Keeping the trailing vertex in
      // every frame yields a stable topology for Lottie's animated sh.
      final parsed = _pathParser.parse(values[i],
          logger: log, dropClosingDuplicate: false);
      if (parsed.isEmpty) {
        log.warn('map.shape',
            'path keyframe failed to parse → static fallback',
            fields: {'id': node.id ?? '', 'index': i});
        return null;
      }
      if (parsed.length > 1 && !warnedMulti) {
        log.warn('map.shape',
            'multi-subpath path animation → animating first subpath only',
            fields: {'id': node.id ?? ''});
        warnedMulti = true;
      }
      contours.add(parsed.first);
    }

    final firstCount = contours.first.vertices.length;
    final firstClosed = contours.first.closed;
    for (var i = 1; i < contours.length; i++) {
      if (contours[i].vertices.length != firstCount ||
          contours[i].closed != firstClosed) {
        log.warn('map.shape',
            'path keyframes have mismatched topology → static fallback',
            fields: {
              'id': node.id ?? '',
              'expected': firstCount,
              'got': contours[i].vertices.length,
            });
        return null;
      }
    }

    final splines = anim.keyframes.keySplines;
    final useSplines =
        anim.keyframes.calcMode == SvgAnimationCalcMode.spline &&
            splines.length == values.length - 1;
    final hold = anim.keyframes.calcMode == SvgAnimationCalcMode.discrete;

    final kfs = <LottieShapePathKeyframe>[];
    for (var i = 0; i < contours.length; i++) {
      final c = contours[i];
      BezierHandle? bIn;
      BezierHandle? bOut;
      if (useSplines && i < splines.length) {
        final s = splines[i];
        bOut = BezierHandle(s.x1, s.y1);
        bIn = BezierHandle(s.x2, s.y2);
      }
      kfs.add(LottieShapePathKeyframe(
        time: keyTimes[i] * anim.durSeconds * _frameRate,
        vertices: c.vertices,
        inTangents: c.inTangents,
        outTangents: c.outTangents,
        closed: c.closed,
        hold: hold,
        bezierIn: bIn,
        bezierOut: bOut,
      ));
    }

    final first = contours.first;
    return LottieShapeGeometry(
      kind: LottieShapeKind.path,
      vertices: first.vertices,
      inTangents: first.inTangents,
      outTangents: first.outTangents,
      closed: first.closed,
      pathKeyframes: kfs,
    );
  }

  LottieShapeGeometry _contourToGeometry(CubicContour c) => LottieShapeGeometry(
        kind: LottieShapeKind.path,
        vertices: c.vertices,
        inTangents: c.inTangents,
        outTangents: c.outTangents,
        closed: c.closed,
      );

  /// Parses a CSS-ish colour into normalised RGBA `[r, g, b, 1]`. Returns
  /// `null` for `none` / `transparent` / `url(#...)` (gradients are a
  /// future stage).
  List<double>? _parseColor(String raw, AnimSvgLogger log) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty || t == 'none' || t == 'transparent') return null;
    if (t.startsWith('url(')) {
      log.warn('map.shape',
          'gradient/pattern fill not yet supported → fallback grey',
          fields: {'fill': raw});
      return const [0.5, 0.5, 0.5, 1];
    }
    if (t.startsWith('#')) {
      return _parseHex(t, log);
    }
    if (t.startsWith('rgb')) {
      return _parseRgbFn(t, log);
    }
    if (t.startsWith('hsl')) {
      return _parseHslFn(t, log);
    }
    final named = _namedColors[t];
    if (named != null) return named;
    log.warn('map.shape', 'unrecognised colour value',
        fields: {'fill': raw});
    return const [0, 0, 0, 1];
  }

  List<double>? _parseHex(String hex, AnimSvgLogger log) {
    var s = hex.substring(1);
    if (s.length == 3) {
      s = '${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}';
    }
    if (s.length != 6) {
      log.warn('map.shape', 'unsupported hex colour', fields: {'fill': hex});
      return const [0, 0, 0, 1];
    }
    final n = int.tryParse(s, radix: 16);
    if (n == null) {
      log.warn('map.shape', 'malformed hex colour', fields: {'fill': hex});
      return const [0, 0, 0, 1];
    }
    final r = ((n >> 16) & 0xFF) / 255.0;
    final g = ((n >> 8) & 0xFF) / 255.0;
    final b = (n & 0xFF) / 255.0;
    return [r, g, b, 1];
  }

  List<double>? _parseRgbFn(String raw, AnimSvgLogger log) {
    final open = raw.indexOf('(');
    final close = raw.lastIndexOf(')');
    if (open < 0 || close < 0) return null;
    final body = raw.substring(open + 1, close);
    final parts = body.split(RegExp(r'[ ,/]+')).where((s) => s.isNotEmpty).toList();
    if (parts.length < 3) {
      log.warn('map.shape', 'rgb() needs 3+ components',
          fields: {'raw': raw});
      return const [0, 0, 0, 1];
    }
    double chan(String s) {
      if (s.endsWith('%')) {
        final n = double.tryParse(s.substring(0, s.length - 1));
        return (n ?? 0) / 100.0;
      }
      return (double.tryParse(s) ?? 0) / 255.0;
    }

    final r = chan(parts[0]);
    final g = chan(parts[1]);
    final b = chan(parts[2]);
    final a = parts.length > 3 ? (double.tryParse(parts[3]) ?? 1) : 1.0;
    return [r, g, b, a];
  }

  List<double>? _parseHslFn(String raw, AnimSvgLogger log) {
    final open = raw.indexOf('(');
    final close = raw.lastIndexOf(')');
    if (open < 0 || close < 0) return null;
    final body = raw.substring(open + 1, close);
    final parts =
        body.split(RegExp(r'[ ,/]+')).where((s) => s.isNotEmpty).toList();
    if (parts.length < 3) {
      log.warn('map.shape', 'hsl() needs 3+ components', fields: {'raw': raw});
      return const [0, 0, 0, 1];
    }
    double parseHue(String s) {
      var v = s;
      if (v.endsWith('deg')) {
        v = v.substring(0, v.length - 3);
      } else if (v.endsWith('turn')) {
        final n = double.tryParse(v.substring(0, v.length - 4)) ?? 0;
        return (n * 360) % 360;
      } else if (v.endsWith('rad')) {
        final n = double.tryParse(v.substring(0, v.length - 3)) ?? 0;
        return (n * 180 / 3.141592653589793) % 360;
      }
      final n = double.tryParse(v) ?? 0;
      return n % 360;
    }

    double parsePct(String s) {
      if (s.endsWith('%')) {
        final n = double.tryParse(s.substring(0, s.length - 1)) ?? 0;
        return (n / 100.0).clamp(0.0, 1.0);
      }
      return (double.tryParse(s) ?? 0).clamp(0.0, 1.0);
    }

    double parseAlpha(String s) {
      if (s.endsWith('%')) {
        final n = double.tryParse(s.substring(0, s.length - 1)) ?? 100;
        return (n / 100.0).clamp(0.0, 1.0);
      }
      return (double.tryParse(s) ?? 1).clamp(0.0, 1.0);
    }

    final h = parseHue(parts[0]);
    final s = parsePct(parts[1]);
    final l = parsePct(parts[2]);
    final a = parts.length > 3 ? parseAlpha(parts[3]) : 1.0;

    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = h / 60.0;
    final x = c * (1 - (hp % 2 - 1).abs());
    double r1 = 0, g1 = 0, b1 = 0;
    if (hp < 1) {
      r1 = c;
      g1 = x;
    } else if (hp < 2) {
      r1 = x;
      g1 = c;
    } else if (hp < 3) {
      g1 = c;
      b1 = x;
    } else if (hp < 4) {
      g1 = x;
      b1 = c;
    } else if (hp < 5) {
      r1 = x;
      b1 = c;
    } else {
      r1 = c;
      b1 = x;
    }
    final m = l - c / 2;
    return [r1 + m, g1 + m, b1 + m, a];
  }

  static const _namedColors = <String, List<double>>{
    'black': [0, 0, 0, 1],
    'white': [1, 1, 1, 1],
    'red': [1, 0, 0, 1],
    'green': [0, 0.5, 0, 1],
    'blue': [0, 0, 1, 1],
    'yellow': [1, 1, 0, 1],
    'cyan': [0, 1, 1, 1],
    'magenta': [1, 0, 1, 1],
    'grey': [0.5, 0.5, 0.5, 1],
    'gray': [0.5, 0.5, 0.5, 1],
  };
}

class _Bbox {
  const _Bbox(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
}
