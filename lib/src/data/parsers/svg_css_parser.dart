import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';

/// Minimal CSS parser for SVG `<style>` blocks that declare
/// `#id { animation: name dur timing iteration ... }` rules backed by
/// `@keyframes name { 0% { ... } 100% { ... } }` blocks.
///
/// The output is a `Map<String id, List<SvgAnimationNode>>` — the same shape
/// the SMIL parser produces — so the mapper downstream doesn't care where
/// the animations came from.
///
/// Supported subset (enough for Figma/Rive/Animate exports):
/// - Selectors: `#id` only. `.class`, tag and compound selectors → WARN + skip.
/// - Properties in keyframes: `transform: translate(...) rotate(...) scale(...)`
///   (in any order; first = replace, rest = sum), `opacity: N`,
///   `offset-distance: N%` (CSS Motion Path — resolved to translate/rotate
///   keyframes by `MotionPathResolver` once the node's `offset-path` is known).
/// - Timing functions (shorthand or per-keyframe via
///   `animation-timing-function:`): `linear`, `ease`, `ease-in`, `ease-out`,
///   `ease-in-out`, `cubic-bezier(x1,y1,x2,y2)`, `step-start`, `step-end`,
///   `steps(n)`. Per-keyframe timing-function governs the SEGMENT starting at
///   that keyframe (CSS Animations L1 §4.3); if any segment has a non-linear
///   spline, the whole track emits `calcMode=spline` with per-segment
///   `keySplines`; linear-only tracks stay `calcMode=linear`.
/// - Durations: `Nms` or `Ns`.
/// - `infinite` keyword → repeatIndefinite. Other iteration counts → not-indefinite.
/// Everything else produces a WARN and is skipped.
class SvgCssParser {
  const SvgCssParser();

  /// Returns per-id animation tracks (as before), per-id static declarations
  /// (from `#id{...}` rules), and per-class static declarations (from
  /// `.cls{...}` rules). Static styles feed the shape-parser cascade
  /// (`inline style > class > id > presentation attr > inherited > default`)
  /// so `<path class="x"/>` with no `id=` still picks up `.x{fill:url(#g);}`.
  ({
    Map<String, List<SvgAnimationNode>> animations,
    Map<String, Map<String, String>> idStyles,
    Map<String, Map<String, String>> classStyles,
  }) parse(
    String css, {
    AnimSvgLogger? logger,
    Map<String, List<String>> classIndex = const {},
  }) {
    final log = logger ?? SilentLogger();
    final stripped = _stripComments(css);
    final rules = _tokenizeRules(stripped);

    // First pass — pick out @keyframes blocks and id rules. A single rule
    // may target several ids via a compound selector (`#a, #b { ... }`)
    // and carry several comma-separated animations, so the storage is
    // `id → list of shorthands`.
    final keyframeBlocks = <String, List<_CssKeyframe>>{};
    final animationRules = <String, List<_AnimationShorthand>>{};
    final idStaticRules = <String, Map<String, String>>{};
    final classStaticRules = <String, Map<String, String>>{};

    for (final rule in rules) {
      final selRaw = rule.selector.trim();
      if (selRaw.startsWith('@keyframes')) {
        final name = selRaw.substring('@keyframes'.length).trim();
        final kfs = _parseKeyframeBlock(rule.body, log, name);
        if (kfs.isNotEmpty) keyframeBlocks[name] = kfs;
        continue;
      }
      // Shared shorthand parsing per rule, then fan out to each sub-selector.
      List<_AnimationShorthand>? shorthands;
      Map<String, String>? staticDecls;
      for (final subRaw in _splitTopLevelCommas(selRaw)) {
        final sub = subRaw.trim();
        List<String>? ids;
        String? className;
        if (sub.startsWith('#')) {
          ids = [sub.substring(1).trim()];
        } else if (sub.startsWith('.')) {
          final cls = sub.substring(1).trim();
          className = cls;
          ids = classIndex[cls] ?? const [];
        } else if (sub.isNotEmpty) {
          log.debug('parse.css', 'skipping non-id/non-class selector',
              fields: {'selector': sub});
          continue;
        } else {
          continue;
        }
        shorthands ??= _parseAnimationShorthand(
            rule.body, log, ids.isNotEmpty ? ids.first : (className ?? ''));
        staticDecls ??= _parseStaticStyleDeclarations(rule.body);
        if (className != null && staticDecls.isNotEmpty) {
          (classStaticRules[className] ??= <String, String>{})
              .addAll(staticDecls);
        }
        for (final id in ids) {
          if (shorthands.isNotEmpty) {
            (animationRules[id] ??= []).addAll(shorthands);
          }
          if (staticDecls.isNotEmpty) {
            (idStaticRules[id] ??= <String, String>{}).addAll(staticDecls);
          }
        }
      }
    }

    // Second pass — join animation rules with their @keyframes block.
    final out = <String, List<SvgAnimationNode>>{};
    for (final entry in animationRules.entries) {
      final id = entry.key;
      for (final shorthand in entry.value) {
        final kfs = keyframeBlocks[shorthand.keyframesName];
        if (kfs == null) {
          log.warn('parse.css', '@keyframes block missing for animation',
              fields: {'id': id, 'name': shorthand.keyframesName});
          continue;
        }
        final anims = _compileAnimations(id, shorthand, kfs, log);
        if (anims.isNotEmpty) {
          (out[id] ??= []).addAll(anims);
        }
      }
    }
    return (
      animations: out,
      idStyles: idStaticRules,
      classStyles: classStaticRules,
    );
  }

  /// Extracts presentation declarations (non-animation) that the shape
  /// parser's fill/opacity cascade consumes. Whitelisted to keep output
  /// small and predictable; unknown properties are silently ignored.
  static const _staticProps = {'fill', 'fill-opacity', 'opacity'};

  Map<String, String> _parseStaticStyleDeclarations(String body) {
    final all = _parseDeclarations(body);
    final out = <String, String>{};
    for (final entry in all.entries) {
      if (_staticProps.contains(entry.key)) {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  /// Splits a CSS fragment on top-level commas (ignoring commas inside
  /// balanced parens, e.g. `cubic-bezier(.25,.1,.25,1)`).
  List<String> _splitTopLevelCommas(String raw) {
    final out = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      if (c == ',' && depth == 0) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  // ---------- tokenization ----------

  String _stripComments(String css) =>
      css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

  /// Splits a CSS document into top-level `selector { body }` rules. Handles
  /// nested `{...}` (e.g. @keyframes with `0% {...}` inside).
  List<_CssRule> _tokenizeRules(String css) {
    final rules = <_CssRule>[];
    var i = 0;
    while (i < css.length) {
      // Scan for opening brace.
      final open = css.indexOf('{', i);
      if (open == -1) break;
      final selector = css.substring(i, open);
      // Match balanced closing brace.
      var depth = 1;
      var j = open + 1;
      while (j < css.length && depth > 0) {
        if (css[j] == '{') {
          depth++;
        } else if (css[j] == '}') {
          depth--;
        }
        j++;
      }
      final body = css.substring(open + 1, j - 1);
      rules.add(_CssRule(selector, body));
      i = j;
    }
    return rules;
  }

  List<_CssKeyframe> _parseKeyframeBlock(
      String body, AnimSvgLogger log, String name) {
    // Each inner rule: `0% { props }`, `from { props }`, etc.
    final inner = _tokenizeRules(body);
    final kfs = <_CssKeyframe>[];
    for (final sub in inner) {
      final decls = _parseDeclarations(sub.body);
      // Per-keyframe `animation-timing-function:` (CSS Animations L1 §4.3)
      // — easing for the segment STARTING at this keyframe. Resolved once
      // here so `_compileAnimations` can zip splines with segments.
      final timingRaw = decls['animation-timing-function']?.trim();
      final outSpline = timingRaw == null ? null : _timingToSpline(timingRaw);
      final isStep = timingRaw != null &&
          (timingRaw == 'step-start' ||
              timingRaw == 'step-end' ||
              timingRaw.startsWith('steps('));
      for (final rawPct in sub.selector.split(',')) {
        final pct = _parsePercent(rawPct.trim());
        if (pct == null) {
          log.warn('parse.css', 'skipping keyframe with invalid percent',
              fields: {'name': name, 'sel': rawPct});
          continue;
        }
        kfs.add(_CssKeyframe(pct, decls, outSpline: outSpline, isStep: isStep));
      }
    }
    kfs.sort((a, b) => a.percent.compareTo(b.percent));
    return kfs;
  }

  double? _parsePercent(String raw) {
    if (raw == 'from') return 0;
    if (raw == 'to') return 1;
    if (raw.endsWith('%')) {
      final n = double.tryParse(raw.substring(0, raw.length - 1));
      if (n == null) return null;
      return n / 100.0;
    }
    return null;
  }

  List<_AnimationShorthand> _parseAnimationShorthand(
      String body, AnimSvgLogger log, String id) {
    final decls = _parseDeclarations(body);
    final anim = decls['animation'];
    // Long-form overrides (§ CSS Animations L1 — individual properties
    // cascade on top of the shorthand when both are present, but in practice
    // exports use one or the other).
    final longDelay = decls['animation-delay']?.trim();
    final longDirection = decls['animation-direction']?.trim();
    final longFillMode = decls['animation-fill-mode']?.trim();
    if (anim != null) {
      final out = <_AnimationShorthand>[];
      for (final seg in _splitTopLevelCommas(anim)) {
        final parsed = _parseOneShorthandSegment(seg.trim(), log, id);
        if (parsed != null) {
          out.add(_applyLongFormOverrides(
              parsed, longDelay, longDirection, longFillMode, log, id));
        }
      }
      if (out.isEmpty) {
        log.warn('parse.css', 'animation shorthand yielded no valid segments',
            fields: {'id': id, 'raw': anim});
      }
      return out;
    }
    // Long-form fallback: animation-name + animation-duration (+ optional
    // animation-timing-function, animation-iteration-count, -delay,
    // -direction, -fill-mode).
    final name = decls['animation-name']?.trim();
    final durStr = decls['animation-duration']?.trim();
    if (name == null || durStr == null) {
      log.debug('parse.css', 'no animation on id rule', fields: {'id': id});
      return const [];
    }
    if (!_isDuration(durStr)) {
      log.warn('parse.css', 'animation-duration not parseable',
          fields: {'id': id, 'value': durStr});
      return const [];
    }
    final timing = decls['animation-timing-function']?.trim() ?? 'linear';
    final iter = decls['animation-iteration-count']?.trim() ?? '';
    var shorthand = _AnimationShorthand(
      keyframesName: name,
      durationSeconds: _parseDurationSeconds(durStr),
      infinite: iter == 'infinite',
      timing: _isTimingFunction(timing) ? timing : 'linear',
    );
    shorthand = _applyLongFormOverrides(
        shorthand, longDelay, longDirection, longFillMode, log, id);
    return [shorthand];
  }

  _AnimationShorthand _applyLongFormOverrides(
    _AnimationShorthand base,
    String? longDelay,
    String? longDirection,
    String? longFillMode,
    AnimSvgLogger log,
    String id,
  ) {
    var delay = base.delaySeconds;
    var direction = base.direction;
    var fillMode = base.fillMode;
    if (longDelay != null && _isDuration(longDelay)) {
      final v = _parseDurationSeconds(longDelay);
      delay = v < 0 ? 0 : v;
      if (v < 0) {
        log.warn('parse.css', 'negative animation-delay clamped to 0',
            fields: {'id': id, 'value': longDelay});
      }
    }
    if (longDirection != null) {
      switch (longDirection) {
        case 'normal':
          direction = SvgAnimationDirection.normal;
        case 'reverse':
          direction = SvgAnimationDirection.reverse;
        case 'alternate':
          direction = SvgAnimationDirection.alternate;
        case 'alternate-reverse':
          direction = SvgAnimationDirection.alternateReverse;
      }
    }
    if (longFillMode != null) {
      switch (longFillMode) {
        case 'none':
          fillMode = SvgAnimationFillMode.none;
        case 'forwards':
          fillMode = SvgAnimationFillMode.forwards;
        case 'backwards':
          fillMode = SvgAnimationFillMode.backwards;
        case 'both':
          fillMode = SvgAnimationFillMode.both;
      }
    }
    return _AnimationShorthand(
      keyframesName: base.keyframesName,
      durationSeconds: base.durationSeconds,
      infinite: base.infinite,
      timing: base.timing,
      delaySeconds: delay,
      direction: direction,
      fillMode: fillMode,
    );
  }

  _AnimationShorthand? _parseOneShorthandSegment(
      String raw, AnimSvgLogger log, String id) {
    // Split by whitespace (cubic-bezier has commas but no spaces inside);
    // classify tokens by type. CSS Animations L1 shorthand order is lenient —
    // durations resolve positionally (1st=duration, 2nd=delay), other tokens
    // are classified by value.
    final tokens = _tokenizeShorthand(raw);
    String? name;
    double? durSec;
    double? delaySec;
    String? timing;
    var infinite = false;
    var direction = SvgAnimationDirection.normal;
    var fillMode = SvgAnimationFillMode.none;
    for (final t in tokens) {
      if (t == 'infinite') {
        infinite = true;
      } else if (_isDuration(t)) {
        if (durSec == null) {
          durSec = _parseDurationSeconds(t);
        } else if (delaySec == null) {
          delaySec = _parseDurationSeconds(t);
        }
      } else if (_isTimingFunction(t)) {
        timing = t;
      } else if (t == 'reverse') {
        direction = SvgAnimationDirection.reverse;
      } else if (t == 'alternate') {
        direction = SvgAnimationDirection.alternate;
      } else if (t == 'alternate-reverse') {
        direction = SvgAnimationDirection.alternateReverse;
      } else if (t == 'forwards') {
        fillMode = fillMode == SvgAnimationFillMode.backwards
            ? SvgAnimationFillMode.both
            : SvgAnimationFillMode.forwards;
      } else if (t == 'backwards') {
        fillMode = fillMode == SvgAnimationFillMode.forwards
            ? SvgAnimationFillMode.both
            : SvgAnimationFillMode.backwards;
      } else if (t == 'both') {
        fillMode = SvgAnimationFillMode.both;
      } else if (_isKeyword(t)) {
        // `normal`, `none`, `paused`, `running` — explicit defaults; no-op.
      } else {
        name ??= t;
      }
    }
    if (name == null || durSec == null) {
      log.warn('parse.css', 'animation shorthand missing name or duration',
          fields: {'id': id, 'raw': raw});
      return null;
    }
    final resolvedDelay = (delaySec ?? 0) < 0 ? 0.0 : (delaySec ?? 0);
    if ((delaySec ?? 0) < 0) {
      log.warn('parse.css',
          'negative animation-delay clamped to 0 (cannot start mid-cycle)',
          fields: {'id': id, 'value': delaySec});
    }
    return _AnimationShorthand(
      keyframesName: name,
      durationSeconds: durSec,
      infinite: infinite,
      timing: timing ?? 'linear',
      delaySeconds: resolvedDelay,
      direction: direction,
      fillMode: fillMode,
    );
  }

  /// Splits an animation shorthand like `name 8000ms linear infinite normal`
  /// into tokens, keeping `cubic-bezier(a,b,c,d)` intact as one token.
  List<String> _tokenizeShorthand(String raw) {
    final tokens = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      if (c == ' ' && depth == 0) {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());
    return tokens;
  }

  bool _isDuration(String t) => _durationRe.hasMatch(t);
  static final _durationRe = RegExp(r'^[\d.]+m?s$');

  bool _isTimingFunction(String t) =>
      const {
        'linear',
        'ease',
        'ease-in',
        'ease-out',
        'ease-in-out',
        'step-start',
        'step-end',
      }.contains(t) ||
      t.startsWith('cubic-bezier(') ||
      t.startsWith('steps(');

  bool _isKeyword(String t) => const {
        'normal',
        'reverse',
        'alternate',
        'alternate-reverse',
        'forwards',
        'backwards',
        'both',
        'none',
        'paused',
        'running',
      }.contains(t);

  double _parseDurationSeconds(String raw) {
    if (raw.endsWith('ms')) {
      return double.parse(raw.substring(0, raw.length - 2)) / 1000.0;
    }
    if (raw.endsWith('s')) {
      return double.parse(raw.substring(0, raw.length - 1));
    }
    return double.parse(raw);
  }

  /// Splits a CSS declaration body `prop: val; prop2: val2;` into a map.
  /// Values containing `:` (e.g. `url(http://...)`) are preserved — we only
  /// split on the first colon per declaration.
  Map<String, String> _parseDeclarations(String body) {
    final out = <String, String>{};
    var depth = 0;
    final buf = StringBuffer();
    final decls = <String>[];
    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      if (c == ';' && depth == 0) {
        decls.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) decls.add(buf.toString());

    for (final d in decls) {
      final colon = d.indexOf(':');
      if (colon == -1) continue;
      final key = d.substring(0, colon).trim();
      final val = d.substring(colon + 1).trim();
      if (key.isNotEmpty) out[key] = val;
    }
    return out;
  }

  // ---------- compilation from CSS tracks → SvgAnimationNode ----------

  List<SvgAnimationNode> _compileAnimations(
    String id,
    _AnimationShorthand shorthand,
    List<_CssKeyframe> kfs,
    AnimSvgLogger log,
  ) {
    // Ensure endpoints at 0 and 1 (css allows implicit missing); if missing,
    // duplicate the closest neighbour.
    if (kfs.first.percent > 0) {
      kfs = [_CssKeyframe(0, kfs.first.declarations), ...kfs];
    }
    if (kfs.last.percent < 1) {
      kfs = [...kfs, _CssKeyframe(1, kfs.last.declarations)];
    }

    final keyTimes = kfs.map((k) => k.percent).toList();

    // Build per-track value lists. Each track may be missing from some
    // keyframes — in that case we carry the last known value forward.
    final transformPerKf = <List<_CssTransform>>[];
    final opacityPerKf = <double?>[];

    List<_CssTransform> lastT = const [];
    double? lastO;
    for (final kf in kfs) {
      final raw = kf.declarations['transform'];
      if (raw != null) {
        lastT = _parseCssTransform(raw, log);
      }
      transformPerKf.add(lastT);

      final rawO = kf.declarations['opacity'];
      if (rawO != null) {
        lastO = double.tryParse(rawO);
      }
      opacityPerKf.add(lastO);
    }

    // Compute per-segment timing: merge per-keyframe `animation-timing-function`
    // (CSS Animations L1 §4.3) with the shorthand-level fallback. The segment
    // starting at kfs[i] uses kfs[i].outSpline if present, otherwise the
    // shorthand spline/mode. Result drives `calcMode` for the whole track
    // plus an explicit `keySplines` list when any segment is non-linear.
    final segCount = keyTimes.length - 1;
    final shorthandMode = _timingToCalcMode(shorthand.timing);
    final shorthandSpline = _timingToSpline(shorthand.timing);
    final segSplines = <BezierSpline?>[];
    final segIsStep = <bool>[];
    for (var i = 0; i < segCount; i++) {
      final kf = kfs[i];
      if (kf.isStep) {
        segSplines.add(null);
        segIsStep.add(true);
      } else if (kf.outSpline != null) {
        segSplines.add(kf.outSpline);
        segIsStep.add(false);
      } else {
        segSplines.add(shorthandMode == SvgAnimationCalcMode.spline
            ? shorthandSpline
            : null);
        segIsStep.add(shorthandMode == SvgAnimationCalcMode.discrete);
      }
    }
    final anyStep = segIsStep.any((s) => s);
    final anySpline = segSplines.any((s) => s != null);
    final allStep = segCount > 0 && segIsStep.every((s) => s);
    SvgAnimationCalcMode calcMode;
    List<BezierSpline> splines;
    if (allStep) {
      calcMode = SvgAnimationCalcMode.discrete;
      splines = const [];
    } else if (anySpline) {
      if (anyStep) {
        log.warn('parse.css',
            'mixed step/spline timing across keyframes; steps become linear',
            fields: {'id': id});
      }
      calcMode = SvgAnimationCalcMode.spline;
      // Linear segments in a spline track get the identity handle (0,0)→(1,1).
      splines = [
        for (final s in segSplines) s ?? const BezierSpline(0, 0, 1, 1),
      ];
    } else {
      calcMode = SvgAnimationCalcMode.linear;
      splines = const [];
    }

    final out = <SvgAnimationNode>[];

    // Transforms: split the per-keyframe list into channels. For each
    // transform function kind (translate / rotate / scale) that varies across
    // keyframes, emit one animateTransform. The FIRST function becomes
    // additive=replace, the rest additive=sum — matches our existing SMIL
    // "pivot chain" semantics.
    final allKinds = <SvgTransformKind>{};
    for (final frame in transformPerKf) {
      for (final t in frame) {
        allKinds.add(t.kind);
      }
    }

    final orderedKinds = transformPerKf.isEmpty
        ? <SvgTransformKind>[]
        : _kindOrder(transformPerKf, allKinds);

    // Build per-kind value lists, then emit ALL of them (even those with
    // constant values) whenever at least one kind varies. This preserves
    // the AE/Figma pivot-pair pattern `translate(p) rotate(t)`: if we
    // dropped the static translate, the emitted replace-rotate would wipe
    // the group's base transform and rotation would happen around (0,0).
    // Policy: first emitted track = additive=replace, rest = sum.
    final pending = <({SvgTransformKind kind, List<String> values})>[];
    for (final kind in orderedKinds) {
      final values = <String>[];
      for (final frame in transformPerKf) {
        final match = frame.firstWhere(
          (t) => t.kind == kind,
          orElse: () => _CssTransform(kind, _identityFor(kind)),
        );
        values.add(match.values.map(_fmt).join(','));
      }
      pending.add((kind: kind, values: values));
    }
    final anyVarying = pending.any((t) => t.values.toSet().length > 1);
    if (anyVarying) {
      for (var i = 0; i < pending.length; i++) {
        out.add(SvgAnimateTransform(
          kind: pending[i].kind,
          durSeconds: shorthand.durationSeconds,
          repeatIndefinite: shorthand.infinite,
          additive: i == 0
              ? SvgAnimationAdditive.replace
              : SvgAnimationAdditive.sum,
          keyframes: SvgKeyframes(
            keyTimes: List.of(keyTimes),
            values: pending[i].values,
            calcMode: calcMode,
            keySplines: splines,
          ),
          delaySeconds: shorthand.delaySeconds,
          direction: shorthand.direction,
          fillMode: shorthand.fillMode,
        ));
      }
    }

    // CSS Motion Path distance channel. Stored as a raw `SvgAnimate` with
    // `attributeName: 'offset-distance'`; values are percent strings
    // (e.g. `"0%"`, `"50%"`). The `MotionPathResolver` later replaces this
    // with translate/rotate tracks sampled along the node's `offset-path`.
    final offsetPerKf = <String?>[];
    String? lastOffset;
    for (final kf in kfs) {
      final raw = kf.declarations['offset-distance'];
      if (raw != null) lastOffset = raw.trim();
      offsetPerKf.add(lastOffset);
    }
    if (offsetPerKf.any((o) => o != null) &&
        offsetPerKf.whereType<String>().toSet().length > 1) {
      final vals = offsetPerKf.map((o) => o ?? '0%').toList();
      out.add(SvgAnimate(
        attributeName: 'offset-distance',
        durSeconds: shorthand.durationSeconds,
        repeatIndefinite: shorthand.infinite,
        additive: SvgAnimationAdditive.replace,
        keyframes: SvgKeyframes(
          keyTimes: List.of(keyTimes),
          values: vals,
          calcMode: calcMode,
          keySplines: splines,
        ),
        delaySeconds: shorthand.delaySeconds,
        direction: shorthand.direction,
        fillMode: shorthand.fillMode,
      ));
    }

    // Opacity channel.
    if (opacityPerKf.any((o) => o != null) &&
        opacityPerKf.whereType<double>().toSet().length > 1) {
      final vals = opacityPerKf
          .map((o) => (o ?? 1).toString())
          .toList();
      out.add(SvgAnimate(
        attributeName: 'opacity',
        durSeconds: shorthand.durationSeconds,
        repeatIndefinite: shorthand.infinite,
        additive: SvgAnimationAdditive.replace,
        keyframes: SvgKeyframes(
          keyTimes: List.of(keyTimes),
          values: vals,
          calcMode: calcMode,
          keySplines: splines,
        ),
        delaySeconds: shorthand.delaySeconds,
        direction: shorthand.direction,
        fillMode: shorthand.fillMode,
      ));
    }

    // Stroke-dashoffset channel (line-drawing "draw-on" exports). The mapper
    // pairs this with a static `stroke-dasharray=L` on the shape and emits a
    // Lottie Trim Paths modifier (`ty:"tm"`).
    final dashoffsetPerKf = <double?>[];
    double? lastDashoffset;
    for (final kf in kfs) {
      final raw = kf.declarations['stroke-dashoffset'];
      if (raw != null) {
        lastDashoffset = double.tryParse(raw.trim()) ?? lastDashoffset;
      }
      dashoffsetPerKf.add(lastDashoffset);
    }
    if (dashoffsetPerKf.any((o) => o != null) &&
        dashoffsetPerKf.whereType<double>().toSet().length > 1) {
      final vals = dashoffsetPerKf.map((o) => (o ?? 0).toString()).toList();
      out.add(SvgAnimate(
        attributeName: 'stroke-dashoffset',
        durSeconds: shorthand.durationSeconds,
        repeatIndefinite: shorthand.infinite,
        additive: SvgAnimationAdditive.replace,
        keyframes: SvgKeyframes(
          keyTimes: List.of(keyTimes),
          values: vals,
          calcMode: calcMode,
          keySplines: splines,
        ),
        delaySeconds: shorthand.delaySeconds,
        direction: shorthand.direction,
        fillMode: shorthand.fillMode,
      ));
    }

    if (out.isEmpty) {
      log.debug('parse.css', 'id has animation but no varying channels',
          fields: {'id': id});
    }
    return out;
  }

  List<double> _identityFor(SvgTransformKind kind) => switch (kind) {
        SvgTransformKind.translate => const [0, 0],
        SvgTransformKind.scale => const [1, 1],
        SvgTransformKind.rotate => const [0],
        SvgTransformKind.matrix => const [1, 0, 0, 1, 0, 0],
        SvgTransformKind.skewX => const [0],
        SvgTransformKind.skewY => const [0],
      };

  /// Emit order: preserve the order transforms first appear in keyframes.
  List<SvgTransformKind> _kindOrder(
    List<List<_CssTransform>> frames,
    Set<SvgTransformKind> allKinds,
  ) {
    final seen = <SvgTransformKind>[];
    for (final frame in frames) {
      for (final t in frame) {
        if (!seen.contains(t.kind)) seen.add(t.kind);
      }
    }
    return seen.where(allKinds.contains).toList();
  }

  String _fmt(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  SvgAnimationCalcMode _timingToCalcMode(String timing) {
    if (timing == 'linear') return SvgAnimationCalcMode.linear;
    if (timing == 'step-start' ||
        timing == 'step-end' ||
        timing.startsWith('steps(')) {
      return SvgAnimationCalcMode.discrete;
    }
    return SvgAnimationCalcMode.spline;
  }

  BezierSpline? _timingToSpline(String timing) {
    if (timing == 'ease') return const BezierSpline(0.25, 0.1, 0.25, 1);
    if (timing == 'ease-in') return const BezierSpline(0.42, 0, 1, 1);
    if (timing == 'ease-out') return const BezierSpline(0, 0, 0.58, 1);
    if (timing == 'ease-in-out') return const BezierSpline(0.42, 0, 0.58, 1);
    if (timing.startsWith('cubic-bezier(')) {
      final body = timing
          .substring('cubic-bezier('.length, timing.length - 1);
      final parts = body.split(',').map((s) => s.trim()).toList();
      if (parts.length != 4) return null;
      try {
        return BezierSpline(
          double.parse(parts[0]),
          double.parse(parts[1]),
          double.parse(parts[2]),
          double.parse(parts[3]),
        );
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  List<_CssTransform> _parseCssTransform(String raw, AnimSvgLogger log) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed == 'none' ||
        trimmed == 'initial' ||
        trimmed == 'inherit' ||
        trimmed == 'unset') {
      return const [];
    }
    final out = <_CssTransform>[];
    final re = RegExp(r'(\w+)\s*\(([^)]*)\)');
    for (final m in re.allMatches(trimmed)) {
      final fn = m.group(1)!;
      final rawArgs = m.group(2)!;
      final args = _parseCssNumbers(rawArgs);
      switch (fn) {
        case 'translate':
        case 'translateX':
        case 'translateY':
        case 'translate3d':
          final x = fn == 'translateY' ? 0.0 : _arg(args, 0, 0);
          final y = fn == 'translateX'
              ? 0.0
              : (fn == 'translateY' ? _arg(args, 0, 0) : _arg(args, 1, 0));
          out.add(_CssTransform(SvgTransformKind.translate, [x, y]));
        case 'scale':
        case 'scaleX':
        case 'scaleY':
        case 'scale3d':
          final sx = fn == 'scaleY' ? 1.0 : _arg(args, 0, 1);
          final sy = fn == 'scale'
              ? _arg(args, 1, _arg(args, 0, 1))
              : (fn == 'scaleY'
                  ? _arg(args, 0, 1)
                  : (fn == 'scale3d' ? _arg(args, 1, 1) : 1.0));
          out.add(_CssTransform(SvgTransformKind.scale, [sx, sy]));
        case 'rotate':
        case 'rotateZ':
          out.add(_CssTransform(
              SvgTransformKind.rotate, [_parseCssAngle(rawArgs)]));
        case 'rotateX':
        case 'rotateY':
        case 'rotate3d':
          log.warn('parse.css', 'skipping 3D rotate (no 2D equivalent)',
              fields: {'fn': fn});
        case 'matrix':
          out.add(_CssTransform(SvgTransformKind.matrix, [
            _arg(args, 0, 1),
            _arg(args, 1, 0),
            _arg(args, 2, 0),
            _arg(args, 3, 1),
            _arg(args, 4, 0),
            _arg(args, 5, 0),
          ]));
        case 'skewX':
          out.add(_CssTransform(
              SvgTransformKind.skewX, [_parseCssAngle(rawArgs)]));
        case 'skewY':
          out.add(_CssTransform(
              SvgTransformKind.skewY, [_parseCssAngle(rawArgs)]));
        default:
          log.warn('parse.css', 'unsupported transform function',
              fields: {'fn': fn});
      }
    }
    return out;
  }

  double _arg(List<double> a, int i, double fallback) =>
      (i >= 0 && i < a.length) ? a[i] : fallback;

  /// Parses the first angle-typed value from a CSS args string and returns
  /// its value in degrees. Recognises `deg` (default), `rad`, `turn`, `grad`.
  double _parseCssAngle(String raw) {
    final m = RegExp(
      r'([-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?)\s*(deg|rad|turn|grad)?',
    ).firstMatch(raw);
    if (m == null) return 0;
    final v = double.tryParse(m.group(1)!) ?? 0;
    switch (m.group(2)) {
      case 'rad':
        return v * 180.0 / 3.141592653589793;
      case 'turn':
        return v * 360.0;
      case 'grad':
        return v * 0.9;
      default:
        return v; // 'deg' or missing
    }
  }

  /// CSS numbers may have `px`, `deg`, `rad`, `%` suffixes — we strip them.
  /// Commas and whitespace are both delimiters.
  List<double> _parseCssNumbers(String raw) {
    final re = RegExp(r'[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?');
    final out = <double>[];
    for (final m in re.allMatches(raw)) {
      final s = m.group(0)!;
      final n = double.tryParse(s);
      if (n != null) out.add(n);
    }
    return out;
  }
}

class _CssRule {
  const _CssRule(this.selector, this.body);
  final String selector;
  final String body;
}

class _CssKeyframe {
  const _CssKeyframe(
    this.percent,
    this.declarations, {
    this.outSpline,
    this.isStep = false,
  });
  final double percent;
  final Map<String, String> declarations;

  /// Easing spline for the segment starting at this keyframe. `null` → fall
  /// back to the shorthand-level timing. A non-null value always overrides.
  final BezierSpline? outSpline;

  /// True when per-keyframe timing is `step-start`, `step-end`, or `steps()`;
  /// the outgoing segment holds until the next keyframe.
  final bool isStep;
}

class _AnimationShorthand {
  const _AnimationShorthand({
    required this.keyframesName,
    required this.durationSeconds,
    required this.infinite,
    required this.timing,
    this.delaySeconds = 0,
    this.direction = SvgAnimationDirection.normal,
    this.fillMode = SvgAnimationFillMode.none,
  });
  final String keyframesName;
  final double durationSeconds;
  final bool infinite;
  final String timing;
  final double delaySeconds;
  final SvgAnimationDirection direction;
  final SvgAnimationFillMode fillMode;
}

class _CssTransform {
  const _CssTransform(this.kind, this.values);
  final SvgTransformKind kind;
  final List<double> values;
}
