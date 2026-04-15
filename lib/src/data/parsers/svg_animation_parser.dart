import 'package:xml/xml.dart';

import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';

class SvgAnimationParser {
  const SvgAnimationParser();

  /// Returns null when the animation is malformed in a way that should be
  /// ignored rather than abort the whole document. Hard ParseExceptions
  /// (structural XML damage) still propagate.
  ///
  /// [parent] — the owning shape/group element. Used by SMIL to-animations
  /// (`<animate to="..."/>` without `from=`) to read the current attribute
  /// value as the starting keyframe.
  SvgAnimationNode? parse(XmlElement el,
      {AnimSvgLogger? logger, XmlElement? parent}) {
    final log = logger ?? SilentLogger();
    switch (el.localName) {
      case 'animate':
        return _parseAnimate(el, log, parent);
      case 'animateTransform':
        return _parseAnimateTransform(el, log, parent);
      default:
        log.warn('parse.anim', 'skipping unsupported animation tag', fields: {
          'tag': el.localName,
          'reason': 'MVP supports <animate> and <animateTransform> only',
        });
        return null;
    }
  }

  SvgAnimate? _parseAnimate(
      XmlElement el, AnimSvgLogger log, XmlElement? parent) {
    final attr = el.getAttribute('attributeName');
    if (attr == null) {
      log.warn('parse.anim', 'skipping <animate> without attributeName',
          fields: {'xml': _short(el)});
      return null;
    }
    final dr = _parseDurAndRepeat(el, log);
    if (dr == null) return null;
    final kfs = _parseKeyframes(el, log, parent);
    if (kfs == null) return null;
    return SvgAnimate(
      attributeName: attr,
      durSeconds: dr.$1,
      repeatIndefinite: dr.$2,
      additive: _parseAdditive(el),
      keyframes: kfs,
    );
  }

  SvgAnimateTransform? _parseAnimateTransform(
      XmlElement el, AnimSvgLogger log, XmlElement? parent) {
    final type = el.getAttribute('type');
    if (type == null) {
      log.warn('parse.anim', 'skipping <animateTransform> without type',
          fields: {'xml': _short(el)});
      return null;
    }
    final kind = switch (type) {
      'translate' => SvgTransformKind.translate,
      'scale' => SvgTransformKind.scale,
      'rotate' => SvgTransformKind.rotate,
      'skewX' => SvgTransformKind.skewX,
      'skewY' => SvgTransformKind.skewY,
      'matrix' => SvgTransformKind.matrix,
      _ => null,
    };
    if (kind == null) {
      log.warn('parse.anim', 'skipping animateTransform with unknown type',
          fields: {'type': type});
      return null;
    }
    final dr = _parseDurAndRepeat(el, log);
    if (dr == null) return null;
    final kfs = _parseKeyframes(el, log, parent);
    if (kfs == null) return null;
    return SvgAnimateTransform(
      kind: kind,
      durSeconds: dr.$1,
      repeatIndefinite: dr.$2,
      additive: _parseAdditive(el),
      keyframes: kfs,
    );
  }

  (double, bool)? _parseDurAndRepeat(XmlElement el, AnimSvgLogger log) {
    final durRaw = el.getAttribute('dur');
    if (durRaw == null) {
      log.warn('parse.anim', 'skipping animation without dur',
          fields: {'xml': _short(el)});
      return null;
    }
    try {
      final dur = _parseDurationSeconds(durRaw);
      final repeat = (el.getAttribute('repeatCount') ?? '') == 'indefinite';
      return (dur, repeat);
    } on FormatException catch (e) {
      log.warn('parse.anim', 'skipping animation with invalid dur',
          fields: {'dur': durRaw, 'err': e.message});
      return null;
    }
  }

  SvgAnimationAdditive _parseAdditive(XmlElement el) {
    return el.getAttribute('additive') == 'sum'
        ? SvgAnimationAdditive.sum
        : SvgAnimationAdditive.replace;
  }

  SvgKeyframes? _parseKeyframes(
      XmlElement el, AnimSvgLogger log, XmlElement? parent) {
    final valuesRaw = el.getAttribute('values');
    List<String> values;
    if (valuesRaw != null) {
      values = valuesRaw
          .split(';')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else {
      final synthesized = _synthesizeFromToBy(el, log, parent);
      if (synthesized == null) return null;
      values = synthesized;
    }

    final keyTimesRaw = el.getAttribute('keyTimes');
    List<double> keyTimes;
    if (keyTimesRaw == null) {
      keyTimes = _implicitKeyTimes(values.length);
    } else {
      try {
        keyTimes = keyTimesRaw
            .split(';')
            .map((s) => double.parse(s.trim()))
            .toList();
      } on FormatException catch (e) {
        log.warn('parse.anim', 'skipping animation with invalid keyTimes',
            fields: {'keyTimes': keyTimesRaw, 'err': e.message});
        return null;
      }
    }

    if (keyTimes.length != values.length) {
      log.warn('parse.anim', 'skipping animation with keyTimes/values mismatch',
          fields: {'kt': keyTimes.length, 'v': values.length});
      return null;
    }

    final calcModeRaw = el.getAttribute('calcMode') ?? 'linear';
    final calcMode = switch (calcModeRaw) {
      'linear' => SvgAnimationCalcMode.linear,
      'spline' => SvgAnimationCalcMode.spline,
      'discrete' => SvgAnimationCalcMode.discrete,
      'paced' => SvgAnimationCalcMode.paced,
      _ => null,
    };
    if (calcMode == null) {
      log.warn('parse.anim', 'unknown calcMode, falling back to linear',
          fields: {'calcMode': calcModeRaw});
    }

    final splinesRaw = el.getAttribute('keySplines');
    final splines = <BezierSpline>[];
    if (splinesRaw != null) {
      for (final entry in splinesRaw.split(';')) {
        final parts = entry
            .trim()
            .split(RegExp(r'[ ,]+'))
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.length != 4) continue;
        try {
          splines.add(BezierSpline(
            double.parse(parts[0]),
            double.parse(parts[1]),
            double.parse(parts[2]),
            double.parse(parts[3]),
          ));
        } on FormatException {
          // skip malformed segment, keep parsing the rest
        }
      }
    }

    return SvgKeyframes(
      keyTimes: keyTimes,
      values: values,
      calcMode: calcMode ?? SvgAnimationCalcMode.linear,
      keySplines: splines,
    );
  }

  List<double> _implicitKeyTimes(int n) {
    if (n <= 1) return [0];
    return List.generate(n, (i) => i / (n - 1));
  }

  /// Synthesizes a two-frame keyframe list from SMIL `from`/`to`/`by` sugar
  /// when no explicit `values=` is provided. Returns null if the combination
  /// cannot be resolved without knowing the element's current value.
  List<String>? _synthesizeFromToBy(
      XmlElement el, AnimSvgLogger log, XmlElement? parent) {
    final from = el.getAttribute('from')?.trim();
    final to = el.getAttribute('to')?.trim();
    final by = el.getAttribute('by')?.trim();

    if (from != null && to != null) return [from, to];
    if (from != null && by != null) {
      final sum = _addNumericLists(from, by);
      if (sum != null) return [from, sum];
      log.warn('parse.anim', 'by sugar requires numeric from/by',
          fields: {'from': from, 'by': by});
      return null;
    }
    if (to != null) {
      // SMIL "to-animation": per spec (§16.2.3) the starting value is the
      // element's current attribute value. When we have the parent element
      // we read that; otherwise fall back to a one-frame snap to target.
      final attrName = el.getAttribute('attributeName');
      if (parent != null && attrName != null) {
        final base = parent.getAttribute(attrName)?.trim();
        if (base != null && base.isNotEmpty) return [base, to];
      }
      return [to, to];
    }
    if (by != null) {
      log.warn('parse.anim', 'by without from is not resolvable',
          fields: {'by': by});
      return null;
    }
    log.warn('parse.anim', 'skipping animation without values= or from/to/by',
        fields: {'xml': _short(el)});
    return null;
  }

  /// Parses two whitespace/comma-separated numeric lists and returns their
  /// component-wise sum serialized back as space-separated numbers. Returns
  /// null if either side is non-numeric or the counts differ.
  String? _addNumericLists(String a, String b) {
    final aParts = a.split(RegExp(r'[ ,]+')).where((s) => s.isNotEmpty).toList();
    final bParts = b.split(RegExp(r'[ ,]+')).where((s) => s.isNotEmpty).toList();
    if (aParts.length != bParts.length || aParts.isEmpty) return null;
    final out = <String>[];
    for (var i = 0; i < aParts.length; i++) {
      final x = double.tryParse(aParts[i]);
      final y = double.tryParse(bParts[i]);
      if (x == null || y == null) return null;
      out.add(_fmt(x + y));
    }
    return out.join(' ');
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  double _parseDurationSeconds(String raw) {
    final trimmed = raw.trim();
    if (trimmed.endsWith('ms')) {
      return double.parse(trimmed.substring(0, trimmed.length - 2)) / 1000.0;
    }
    if (trimmed.endsWith('s')) {
      return double.parse(trimmed.substring(0, trimmed.length - 1));
    }
    return double.parse(trimmed);
  }

  String _short(XmlElement el) {
    final s = el.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

