import 'dart:convert';

import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_transform.dart';

/// Parses the JSON payload that the Svgator exporter emits inside a
/// `<script>` tag alongside the SVG geometry, e.g.:
///
///   (function(s,i,u,o,c,...){...})(
///       '91c80d77',
///       {"root":"...","animations":[{"elements":{...}}],...},
///       'https://cdn.svgator.com/ply/',
///       ...);
///
/// We pull out the **second** positional argument (the `i` object literal)
/// and translate per-element keyframe tracks into the same
/// [SvgAnimationNode] / [SvgStaticTransform] domain shapes that the SMIL and
/// CSS parsers produce. The downstream mapper is format-agnostic — it only
/// cares about `attributeName`, `kind`, and the [SvgKeyframes] payload.
///
/// Scope today: every property observed in Svgator exports
/// (`d`, `opacity`, `fill-opacity`, `stroke-dashoffset`, `stroke-dasharray`,
/// `transform.data/keys` → translate/scale/rotate/origin). Animated gradient
/// `fill` is parsed-but-skipped with a warn — the shape mapper has no string
/// contract for gradient-over-time, and the static gradient still renders
/// correctly via the `<defs>` pipeline.
class SvgSvgatorParser {
  const SvgSvgatorParser();

  /// Parses the concatenated text of all `<script>` blocks found inside the
  /// SVG document and returns the per-element animation and static-transform
  /// maps, keyed by SVG element `id`. Returns empty maps when no Svgator
  /// payload is present.
  ({
    Map<String, List<SvgAnimationNode>> animations,
    Map<String, List<SvgStaticTransform>> staticTransforms,
  }) parse(String scriptText, {AnimSvgLogger? logger}) {
    final log = logger ?? SilentLogger();
    if (scriptText.trim().isEmpty) {
      return (animations: const {}, staticTransforms: const {});
    }

    final payload = _extractPayload(scriptText, log);
    if (payload == null) {
      return (animations: const {}, staticTransforms: const {});
    }

    final animsList = payload['animations'];
    if (animsList is! List) {
      log.warn('parse.svgator', 'payload has no animations array');
      return (animations: const {}, staticTransforms: const {});
    }

    final animations = <String, List<SvgAnimationNode>>{};
    final staticTransforms = <String, List<SvgStaticTransform>>{};
    var totalTracks = 0;
    var totalElements = 0;

    for (final group in animsList) {
      if (group is! Map) continue;
      final elements = group['elements'];
      if (elements is! Map) continue;
      for (final entry in elements.entries) {
        final elementId = entry.key?.toString();
        final props = entry.value;
        if (elementId == null || elementId.isEmpty || props is! Map) continue;
        totalElements++;
        final collected = _parseElement(elementId, props, log);
        if (collected.animations.isNotEmpty) {
          (animations[elementId] ??= []).addAll(collected.animations);
          totalTracks += collected.animations.length;
        }
        if (collected.statics.isNotEmpty) {
          (staticTransforms[elementId] ??= []).addAll(collected.statics);
        }
      }
    }

    log.info('parse.svgator', 'payload extracted', fields: {
      'elements': totalElements,
      'tracks': totalTracks,
    });

    return (animations: animations, staticTransforms: staticTransforms);
  }

  /// Locates the Svgator JSON literal inside the IIFE argument list. The
  /// exporter uses a well-known boilerplate: the first positional argument is
  /// a short hash string in single quotes, the second is an object literal
  /// holding the animation data, followed by the CDN URL `'https://.../ply/'`.
  /// We anchor on that URL to guarantee we parsed the right exporter.
  Map<String, dynamic>? _extractPayload(String source, AnimSvgLogger log) {
    final cdnIdx = source.indexOf("'https://cdn.svgator.com");
    if (cdnIdx < 0) {
      log.debug('parse.svgator', 'no svgator payload marker found');
      return null;
    }

    // Scan backward from the CDN URL to find the opening '{' of the JSON
    // object argument. We skip whitespace and commas between arguments.
    var i = cdnIdx - 1;
    while (i >= 0 && (source[i] == ' ' || source[i] == ',' || source[i] == '\n' || source[i] == '\t' || source[i] == '\r')) {
      i--;
    }
    if (i < 0 || source[i] != '}') {
      log.warn('parse.svgator', 'payload not terminated by }');
      return null;
    }
    final end = i + 1;

    // Balance-match backward to find the paired '{'.
    var depth = 0;
    var start = -1;
    var inString = false;
    String? quote;
    for (var j = end - 1; j >= 0; j--) {
      final c = source[j];
      if (inString) {
        if (c == quote && (j == 0 || source[j - 1] != '\\')) {
          inString = false;
          quote = null;
        }
        continue;
      }
      if (c == '"' || c == "'") {
        inString = true;
        quote = c;
        continue;
      }
      if (c == '}') depth++;
      if (c == '{') {
        depth--;
        if (depth == 0) {
          start = j;
          break;
        }
      }
    }
    if (start < 0) {
      log.warn('parse.svgator', 'could not balance { } in payload');
      return null;
    }

    final raw = source.substring(start, end);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      log.warn('parse.svgator', 'payload is not a JSON object');
      return null;
    } on FormatException catch (e) {
      log.warn('parse.svgator', 'payload JSON parse failed',
          fields: {'err': e.message});
      return null;
    }
  }

  _ElementTracks _parseElement(
      String id, Map props, AnimSvgLogger log) {
    final anims = <SvgAnimationNode>[];
    final statics = <SvgStaticTransform>[];

    for (final entry in props.entries) {
      final key = entry.key?.toString();
      final value = entry.value;
      if (key == null) continue;
      switch (key) {
        case 'd':
          final a = _parsePathTrack(id, value, log);
          if (a != null) anims.add(a);
        case 'opacity':
        case 'fill-opacity':
        case 'stroke-dashoffset':
          final a = _parseScalarTrack(id, key, value, log);
          if (a != null) anims.add(a);
        case 'stroke-dasharray':
          final a = _parseVectorTrack(id, key, value, log);
          if (a != null) anims.add(a);
        case 'fill':
          log.warn('parse.svgator',
              'animated fill (gradient) not yet supported → static fallback',
              fields: {'id': id});
        case 'transform':
          if (value is Map) {
            _parseTransform(id, value, anims, statics, log);
          }
        default:
          log.debug('parse.svgator', 'skipping unknown property',
              fields: {'id': id, 'prop': key});
      }
    }

    return _ElementTracks(anims, statics);
  }

  // ───────────────────────────── scalar / vector / path tracks

  SvgAnimate? _parseScalarTrack(
      String id, String attr, dynamic value, AnimSvgLogger log) {
    final frames = _coerceFrames(value);
    if (frames == null || frames.length < 2) {
      if (frames != null && frames.length == 1) {
        log.debug('parse.svgator', 'single-frame scalar → skipping',
            fields: {'id': id, 'attr': attr});
      }
      return null;
    }
    final values = <String>[];
    for (final f in frames) {
      final v = f['v'];
      if (v is! num) {
        log.warn('parse.svgator', 'non-numeric scalar keyframe → skip track',
            fields: {'id': id, 'attr': attr});
        return null;
      }
      values.add(_fmt(v.toDouble()));
    }
    return _buildAnimate(attr, frames, values);
  }

  SvgAnimate? _parseVectorTrack(
      String id, String attr, dynamic value, AnimSvgLogger log) {
    final frames = _coerceFrames(value);
    if (frames == null || frames.length < 2) return null;
    final values = <String>[];
    for (final f in frames) {
      final v = f['v'];
      if (v is! List) {
        log.warn('parse.svgator', 'non-list vector keyframe → skip track',
            fields: {'id': id, 'attr': attr});
        return null;
      }
      values.add(v.whereType<num>().map((n) => _fmt(n.toDouble())).join(','));
    }
    return _buildAnimate(attr, frames, values);
  }

  SvgAnimate? _parsePathTrack(String id, dynamic value, AnimSvgLogger log) {
    final frames = _coerceFrames(value);
    if (frames == null || frames.length < 2) return null;
    final values = <String>[];
    for (final f in frames) {
      final v = f['v'];
      if (v is! List) {
        log.warn('parse.svgator', 'path keyframe is not a list → skip track',
            fields: {'id': id});
        return null;
      }
      final str = _serializePath(v);
      if (str == null) {
        log.warn('parse.svgator', 'path keyframe serialization failed → skip',
            fields: {'id': id});
        return null;
      }
      values.add(str);
    }
    return _buildAnimate('d', frames, values);
  }

  // ───────────────────────────── transform block (data + keys)

  void _parseTransform(
      String id,
      Map transform,
      List<SvgAnimationNode> anims,
      List<SvgStaticTransform> statics,
      AnimSvgLogger log) {
    final data = transform['data'];
    final keys = transform['keys'];

    final staticT = (data is Map) ? _readXY(data['t']) : null;
    final staticO = (data is Map) ? _readXY(data['o']) : null;
    final staticR = (data is Map) ? _readNum(data['r']) : null;

    final animT = (keys is Map) ? _coerceFrames(keys['t']) : null;
    final animO = (keys is Map) ? _coerceFrames(keys['o']) : null;
    final animS = (keys is Map) ? _coerceFrames(keys['s']) : null;
    final animR = (keys is Map) ? _coerceFrames(keys['r']) : null;

    // Translate (position). Prefer animated keys.t; else emit static data.t.
    // When neither is present but keys.o is animated, keys.o maps to position
    // (Svgator's transform-origin animation doubles as world-space placement).
    if (animT != null && animT.length >= 2) {
      final vals = _xyValues(animT, log, id: id, attr: 'transform.t');
      if (vals != null) {
        anims.add(SvgAnimateTransform(
          kind: SvgTransformKind.translate,
          durSeconds: _durOf(animT),
          repeatIndefinite: true,
          additive: SvgAnimationAdditive.replace,
          keyframes: _keyframes(animT, vals),
          delaySeconds: _delayOf(animT),
        ));
      }
    } else if (animO != null && animO.length >= 2) {
      final vals = _xyValues(animO, log, id: id, attr: 'transform.o');
      if (vals != null) {
        anims.add(SvgAnimateTransform(
          kind: SvgTransformKind.translate,
          durSeconds: _durOf(animO),
          repeatIndefinite: true,
          additive: SvgAnimationAdditive.replace,
          keyframes: _keyframes(animO, vals),
          delaySeconds: _delayOf(animO),
        ));
      }
    } else if (staticT != null) {
      statics.add(SvgStaticTransform(
        kind: SvgTransformKind.translate,
        values: [staticT.$1, staticT.$2],
      ));
    } else if (staticO != null) {
      statics.add(SvgStaticTransform(
        kind: SvgTransformKind.translate,
        values: [staticO.$1, staticO.$2],
      ));
    }

    // Scale.
    if (animS != null && animS.length >= 2) {
      final vals = _xyValues(animS, log, id: id, attr: 'transform.s');
      if (vals != null) {
        anims.add(SvgAnimateTransform(
          kind: SvgTransformKind.scale,
          durSeconds: _durOf(animS),
          repeatIndefinite: true,
          additive: SvgAnimationAdditive.replace,
          keyframes: _keyframes(animS, vals),
          delaySeconds: _delayOf(animS),
        ));
      }
    }

    // Rotate.
    if (animR != null && animR.length >= 2) {
      final vals = <String>[];
      for (final f in animR) {
        final v = f['v'];
        if (v is num) {
          vals.add(_fmt(v.toDouble()));
        } else {
          log.warn('parse.svgator', 'non-numeric rotate keyframe → skip track',
              fields: {'id': id});
          vals.clear();
          break;
        }
      }
      if (vals.length == animR.length) {
        anims.add(SvgAnimateTransform(
          kind: SvgTransformKind.rotate,
          durSeconds: _durOf(animR),
          repeatIndefinite: true,
          additive: SvgAnimationAdditive.replace,
          keyframes: _keyframes(animR, vals),
          delaySeconds: _delayOf(animR),
        ));
      }
    } else if (staticR != null && staticR != 0) {
      statics.add(SvgStaticTransform(
        kind: SvgTransformKind.rotate,
        values: [staticR, 0, 0],
      ));
    }

    // Pivot compensation: when scale or rotate is animated but `keys.o` is
    // not, emit a constant `additive=sum` translate whose value is the static
    // origin. transform_mapper sign-flips it onto Lottie's anchor, so
    // rotation/scale pivot around `data.o` instead of around (0,0).
    final needsPivot = (animS != null && animS.length >= 2) ||
        (animR != null && animR.length >= 2);
    final animOriginHandled = animO != null && animO.length >= 2;
    if (needsPivot && !animOriginHandled && staticO != null) {
      final v = '${_fmt(-staticO.$1)},${_fmt(-staticO.$2)}';
      anims.add(SvgAnimateTransform(
        kind: SvgTransformKind.translate,
        durSeconds: 0.001,
        repeatIndefinite: true,
        additive: SvgAnimationAdditive.sum,
        keyframes: SvgKeyframes(
          keyTimes: const [0.0, 1.0],
          values: [v, v],
          calcMode: SvgAnimationCalcMode.linear,
          keySplines: const [BezierSpline(0, 0, 1, 1)],
        ),
      ));
    }
  }

  // ───────────────────────────── helpers

  List<Map>? _coerceFrames(dynamic raw) {
    if (raw is! List) return null;
    final out = <Map>[];
    for (final f in raw) {
      if (f is Map && f['t'] is num) out.add(f);
    }
    return out.isEmpty ? null : out;
  }

  (double, double)? _readXY(dynamic raw) {
    if (raw is Map) {
      final x = raw['x'];
      final y = raw['y'];
      if (x is num && y is num) return (x.toDouble(), y.toDouble());
    }
    return null;
  }

  double? _readNum(dynamic raw) => raw is num ? raw.toDouble() : null;

  double _durOf(List<Map> frames) {
    final minT = (frames.first['t'] as num).toDouble();
    final maxT = (frames.last['t'] as num).toDouble();
    final span = (maxT - minT) / 1000.0;
    return span > 0 ? span : 0.001;
  }

  double _delayOf(List<Map> frames) {
    final minT = (frames.first['t'] as num).toDouble();
    return minT > 0 ? minT / 1000.0 : 0;
  }

  /// Builds an [SvgKeyframes] with normalized `[0..1]` times, spline easing
  /// collected from per-frame `e:[x1,y1,x2,y2]` (linear when absent), and
  /// the caller-provided serialized value strings.
  SvgKeyframes _keyframes(List<Map> frames, List<String> values) {
    final minT = (frames.first['t'] as num).toDouble();
    final maxT = (frames.last['t'] as num).toDouble();
    final span = (maxT - minT);
    final keyTimes = <double>[];
    for (final f in frames) {
      final t = (f['t'] as num).toDouble();
      keyTimes.add(span > 0 ? (t - minT) / span : 0);
    }
    final splines = <BezierSpline>[];
    for (var i = 0; i < frames.length - 1; i++) {
      final e = frames[i]['e'];
      if (e is List && e.length >= 4 &&
          e[0] is num && e[1] is num && e[2] is num && e[3] is num) {
        splines.add(BezierSpline(
          (e[0] as num).toDouble(),
          (e[1] as num).toDouble(),
          (e[2] as num).toDouble(),
          (e[3] as num).toDouble(),
        ));
      } else {
        splines.add(const BezierSpline(0, 0, 1, 1));
      }
    }
    return SvgKeyframes(
      keyTimes: keyTimes,
      values: values,
      calcMode: SvgAnimationCalcMode.spline,
      keySplines: splines,
    );
  }

  SvgAnimate _buildAnimate(
      String attr, List<Map> frames, List<String> values) {
    return SvgAnimate(
      attributeName: attr,
      durSeconds: _durOf(frames),
      repeatIndefinite: true,
      additive: SvgAnimationAdditive.replace,
      keyframes: _keyframes(frames, values),
      delaySeconds: _delayOf(frames),
    );
  }

  /// Extracts `"x,y"`-serialized values from keyframes whose `v` is `{x,y}`.
  /// Returns null (caller skips track) if any frame has a malformed `v`.
  List<String>? _xyValues(List<Map> frames, AnimSvgLogger log,
      {required String id, required String attr}) {
    final out = <String>[];
    for (final f in frames) {
      final xy = _readXY(f['v']);
      if (xy == null) {
        log.warn('parse.svgator', 'malformed xy keyframe → skip track',
            fields: {'id': id, 'attr': attr});
        return null;
      }
      out.add('${_fmt(xy.$1)},${_fmt(xy.$2)}');
    }
    return out;
  }

  /// Serializes a Svgator path-command array back to an SVG path string. The
  /// array alternates between a string command letter (`M`, `L`, `C`, `Z`,
  /// etc.) and its numeric arguments, e.g.
  /// `["M", 10, 20, "L", 30, 40, "Z"]` → `"M 10,20 L 30,40 Z"`.
  String? _serializePath(List cmds) {
    final buf = StringBuffer();
    for (var i = 0; i < cmds.length;) {
      final tok = cmds[i];
      if (tok is! String) return null;
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(tok);
      i++;
      // consume trailing numbers until next letter or end
      while (i < cmds.length && cmds[i] is num) {
        buf.write(' ');
        buf.write(_fmt((cmds[i] as num).toDouble()));
        i++;
      }
    }
    return buf.toString();
  }

  String _fmt(double v) {
    if (v.isNaN || v.isInfinite) return '0';
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toStringAsFixed(0);
    }
    return v.toString();
  }
}

class _ElementTracks {
  _ElementTracks(this.animations, this.statics);
  final List<SvgAnimationNode> animations;
  final List<SvgStaticTransform> statics;
}

