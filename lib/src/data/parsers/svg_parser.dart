import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../domain/entities/svg_animation.dart';
import '../../domain/entities/svg_document.dart';
import '../../domain/entities/svg_motion_path.dart';
import '../../domain/entities/svg_transform.dart';
import 'svg_animation_parser.dart';
import 'svg_css_parser.dart';
import 'svg_svgator_parser.dart';
import 'svg_transform_parser.dart';

class SvgParser {
  SvgParser({
    SvgAnimationParser? animations,
    SvgTransformParser? transforms,
    SvgCssParser? css,
    SvgSvgatorParser? svgator,
    AnimSvgLogger? logger,
  })  : _animations = animations ?? const SvgAnimationParser(),
        _transforms = transforms ?? const SvgTransformParser(),
        _css = css ?? const SvgCssParser(),
        _svgator = svgator ?? const SvgSvgatorParser(),
        _log = logger ?? SilentLogger();

  final SvgAnimationParser _animations;
  final SvgTransformParser _transforms;
  final SvgCssParser _css;
  final SvgSvgatorParser _svgator;
  final AnimSvgLogger _log;

  /// Per-parse scratch: Svgator-derived static transforms keyed by element id.
  /// Written once at the top of [parse] and read by [_parseTransformsAndAnimations]
  /// as each shape/group is materialised.
  Map<String, List<SvgStaticTransform>> _svgatorStatics =
      const <String, List<SvgStaticTransform>>{};

  SvgDocument parse(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final root = doc.rootElement;
    if (root.localName != 'svg') {
      throw ParseException('root element is not <svg>');
    }

    final width = _parseLength(root.getAttribute('width'));
    final height = _parseLength(root.getAttribute('height'));
    final viewBox = _parseViewBox(root.getAttribute('viewBox'), width, height);

    final cssBlob = root.descendants
        .whereType<XmlElement>()
        .where((e) => e.localName == 'style')
        .map((e) => e.innerText)
        .join('\n');
    final classIndex = _buildClassIndex(root);
    Map<String, List<SvgAnimationNode>> cssAnims;
    _CssStatics cssStatics;
    if (cssBlob.trim().isEmpty) {
      cssAnims = <String, List<SvgAnimationNode>>{};
      cssStatics = const _CssStatics();
    } else {
      final parsed = _css.parse(cssBlob, logger: _log, classIndex: classIndex);
      cssAnims = {...parsed.animations};
      cssStatics = _CssStatics(
        byId: parsed.idStyles,
        byClass: parsed.classStyles,
      );
    }

    // Svgator-exported SVGs embed their animation data in a <script> block.
    // Extract any such payload and merge into the per-id animation map so
    // downstream mappers see a unified view regardless of source format.
    final scriptBlob = root.descendants
        .whereType<XmlElement>()
        .where((e) => e.localName == 'script')
        .map((e) => e.innerText)
        .join('\n');
    _svgatorStatics = const <String, List<SvgStaticTransform>>{};
    if (scriptBlob.trim().isNotEmpty) {
      final parsed = _svgator.parse(scriptBlob, logger: _log);
      for (final entry in parsed.animations.entries) {
        (cssAnims[entry.key] ??= <SvgAnimationNode>[]).addAll(entry.value);
      }
      _svgatorStatics = parsed.staticTransforms;
    }

    final defsMap = <String, SvgNode>{};
    final gradientMap = <String, SvgGradient>{};
    final filterMap = <String, SvgFilter>{};
    final maskMap = <String, SvgMask>{};
    for (final defs in root.findElements('defs')) {
      for (final child in defs.childElements) {
        final tag = child.localName;
        if (tag == 'linearGradient' || tag == 'radialGradient') {
          final grad = _parseGradient(child);
          if (grad != null) gradientMap[grad.id] = grad;
          continue;
        }
        if (tag == 'filter') {
          final f = _parseFilter(child);
          if (f != null) filterMap[f.id] = f;
          continue;
        }
        if (tag == 'mask') {
          final m = _parseMask(child, cssAnims, cssStatics);
          if (m != null) maskMap[m.id] = m;
          continue;
        }
        if (_isDecorativeSkip(tag)) continue;
        final node = _parseNode(child, cssAnims, cssStatics);
        if (node == null) continue;
        final id = node.id;
        if (id != null) defsMap[id] = node;
      }
    }
    // Illustrator-exported SVGs sometimes place <linearGradient>/<filter>/<mask>
    // at the root instead of inside <defs>. Scan the root for them so
    // `fill="url(#id)"` / `mask="url(#id)"` references resolve.
    for (final child in root.childElements) {
      final tag = child.localName;
      if (tag == 'linearGradient' || tag == 'radialGradient') {
        final grad = _parseGradient(child);
        if (grad != null) gradientMap[grad.id] = grad;
      } else if (tag == 'filter') {
        final f = _parseFilter(child);
        if (f != null) filterMap[f.id] = f;
      } else if (tag == 'mask') {
        final m = _parseMask(child, cssAnims, cssStatics);
        if (m != null) maskMap[m.id] = m;
      }
    }
    _resolveGradientHrefs(gradientMap);

    final rootChildren = <SvgNode>[];
    for (final child in root.childElements) {
      final tag = child.localName;
      if (tag == 'defs') continue;
      if (tag == 'linearGradient' ||
          tag == 'radialGradient' ||
          tag == 'filter' ||
          tag == 'mask') continue;
      if (_isDecorativeSkip(tag)) continue;
      final n = _parseNode(child, cssAnims, cssStatics);
      if (n != null) rootChildren.add(n);
    }

    return SvgDocument(
      width: width ?? viewBox.w,
      height: height ?? viewBox.h,
      viewBox: viewBox,
      defs: SvgDefs(
        defsMap,
        gradients: gradientMap,
        filters: filterMap,
        masks: maskMap,
      ),
      root: SvgGroup(
        staticTransforms: const [],
        animations: const [],
        children: rootChildren,
      ),
    );
  }

  SvgGradient? _parseGradient(XmlElement el) {
    final id = el.getAttribute('id');
    if (id == null) {
      _log.warn('parse.gradient', 'gradient without id; skipping',
          fields: {'tag': el.localName});
      return null;
    }
    final kind = el.localName == 'radialGradient'
        ? SvgGradientKind.radial
        : SvgGradientKind.linear;
    final unitsRaw = el.getAttribute('gradientUnits');
    final units = unitsRaw == 'userSpaceOnUse'
        ? SvgGradientUnits.userSpaceOnUse
        : SvgGradientUnits.objectBoundingBox;
    final gtRaw = el.getAttribute('gradientTransform');
    final hasGT = gtRaw != null;
    final gradientTransform =
        hasGT ? _parseAffineMatrix(gtRaw) : null;
    final stops = <SvgStop>[];
    for (final child in el.childElements) {
      if (child.localName != 'stop') continue;
      final stop = _parseStop(child);
      if (stop != null) stops.add(stop);
    }
    return SvgGradient(
      id: id,
      kind: kind,
      stops: stops,
      units: units,
      x1: _parseLength(el.getAttribute('x1')) ?? 0,
      y1: _parseLength(el.getAttribute('y1')) ?? 0,
      x2: _parseLength(el.getAttribute('x2')) ?? 1,
      y2: _parseLength(el.getAttribute('y2')) ?? 0,
      cx: _parseLength(el.getAttribute('cx')) ?? 0.5,
      cy: _parseLength(el.getAttribute('cy')) ?? 0.5,
      r: _parseLength(el.getAttribute('r')) ?? 0.5,
      fx: _parseLength(el.getAttribute('fx')),
      fy: _parseLength(el.getAttribute('fy')),
      hasGradientTransform: hasGT,
      gradientTransform: gradientTransform,
    );
  }

  /// Parses an SVG `transform`-style string into a flat 2D affine matrix
  /// `[a, b, c, d, e, f]`. Supports translate/scale/rotate/skewX/skewY/matrix.
  /// Composes left-to-right so the result applied to a point matches the SVG
  /// semantics (`transform="A B"` means `A(B(p))`).
  List<double>? _parseAffineMatrix(String raw) {
    final re = RegExp(r'(\w+)\s*\(([^)]*)\)');
    final matches = re.allMatches(raw).toList();
    if (matches.isEmpty) return null;
    var m = <double>[1, 0, 0, 1, 0, 0];
    List<double> mul(List<double> a, List<double> b) {
      return [
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
      ];
    }

    for (final match in matches) {
      final name = match.group(1)!;
      final args = RegExp(r'[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?')
          .allMatches(match.group(2)!)
          .map((x) => double.parse(x.group(0)!))
          .toList();
      List<double>? n;
      switch (name) {
        case 'translate':
          final tx = args.isNotEmpty ? args[0] : 0.0;
          final ty = args.length > 1 ? args[1] : 0.0;
          n = [1, 0, 0, 1, tx, ty];
        case 'scale':
          final sx = args.isNotEmpty ? args[0] : 1.0;
          final sy = args.length > 1 ? args[1] : sx;
          n = [sx, 0, 0, sy, 0, 0];
        case 'rotate':
          final rad = (args.isNotEmpty ? args[0] : 0.0) * 3.141592653589793 / 180.0;
          final c = math.cos(rad), s = math.sin(rad);
          if (args.length >= 3) {
            final cx = args[1], cy = args[2];
            n = mul(
                [1, 0, 0, 1, cx, cy],
                mul([c, s, -s, c, 0, 0], [1, 0, 0, 1, -cx, -cy]));
          } else {
            n = [c, s, -s, c, 0, 0];
          }
        case 'skewX':
          final t = math.tan((args.isNotEmpty ? args[0] : 0.0) *
              3.141592653589793 / 180.0);
          n = [1, 0, t, 1, 0, 0];
        case 'skewY':
          final t = math.tan((args.isNotEmpty ? args[0] : 0.0) *
              3.141592653589793 / 180.0);
          n = [1, t, 0, 1, 0, 0];
        case 'matrix':
          if (args.length == 6) n = args;
      }
      if (n != null) m = mul(m, n);
    }
    return m;
  }

  SvgStop? _parseStop(XmlElement el) {
    final offsetRaw = el.getAttribute('offset') ?? '0';
    final offset = _parseOffset(offsetRaw);
    final style = _parseInlineStyle(el.getAttribute('style'));
    final color = style['stop-color'] ?? el.getAttribute('stop-color') ?? '#000';
    final opRaw =
        style['stop-opacity'] ?? el.getAttribute('stop-opacity') ?? '1';
    final opacity = double.tryParse(opRaw) ?? 1.0;
    final anims = <SvgAnimationNode>[];
    for (final child in el.childElements) {
      if (!_isAnimationTag(child)) continue;
      final n = _animations.parse(child, logger: _log);
      if (n != null) anims.add(n);
    }
    return SvgStop(
      offset: offset,
      color: color,
      stopOpacity: opacity,
      animations: anims,
    );
  }

  double _parseOffset(String raw) {
    final t = raw.trim();
    if (t.endsWith('%')) {
      final n = double.tryParse(t.substring(0, t.length - 1));
      return (n ?? 0) / 100.0;
    }
    return double.tryParse(t) ?? 0;
  }

  /// `<linearGradient xlink:href="#base">` — some SVGs define colour stops
  /// on a base gradient and geometry on the referrer. Walk the chain once
  /// to copy stops from the referenced gradient into the referrer.
  void _resolveGradientHrefs(Map<String, SvgGradient> map) {
    // href is not currently parsed separately — skip for MVP. Present as a
    // hook so future extensions slot in without touching call-sites.
  }

  /// Parses a `<mask>` element into [SvgMask]. The mask's child elements are
  /// recursively parsed as regular renderable nodes (their luminance — or
  /// alpha, for `mask-type="alpha"` — becomes the matte source downstream).
  /// Attribute animations inside the mask are ignored: the mask source is
  /// baked at t=0 since Lottie track mattes don't animate independently of
  /// their target.
  SvgMask? _parseMask(
      XmlElement el,
      Map<String, List<SvgAnimationNode>> cssAnims,
      _CssStatics cssStatics) {
    final id = el.getAttribute('id');
    if (id == null) {
      _log.warn('parse.mask', 'mask without id; skipping');
      return null;
    }
    final type = (el.getAttribute('mask-type') ?? 'luminance').toLowerCase() ==
            'alpha'
        ? SvgMaskType.alpha
        : SvgMaskType.luminance;
    final maskUnits = el.getAttribute('maskUnits') == 'userSpaceOnUse'
        ? SvgMaskUnits.userSpaceOnUse
        : SvgMaskUnits.objectBoundingBox;
    final maskContentUnits =
        el.getAttribute('maskContentUnits') == 'objectBoundingBox'
            ? SvgMaskUnits.objectBoundingBox
            : SvgMaskUnits.userSpaceOnUse;

    final children = <SvgNode>[];
    for (final child in el.childElements) {
      if (_isAnimationTag(child)) continue;
      if (_isDecorativeSkip(child.localName)) continue;
      if (child.localName == 'mask') continue; // nested masks: not supported
      final n = _parseNode(child, cssAnims, cssStatics);
      if (n != null) children.add(n);
    }
    if (children.isEmpty) {
      _log.warn('parse.mask', 'mask has no renderable children',
          fields: {'id': id});
    }
    return SvgMask(
      id: id,
      children: children,
      type: type,
      x: _parsePercentOrLength(el.getAttribute('x'), -0.1),
      y: _parsePercentOrLength(el.getAttribute('y'), -0.1),
      width: _parsePercentOrLength(el.getAttribute('width'), 1.2),
      height: _parsePercentOrLength(el.getAttribute('height'), 1.2),
      maskUnits: maskUnits,
      maskContentUnits: maskContentUnits,
    );
  }

  /// Best-effort interpretation of a mask bbox attribute. `%` suffixed values
  /// map to a fractional bbox unit (100% → 1.0). Plain numbers are passed
  /// through. `null` falls back to the provided default.
  double _parsePercentOrLength(String? raw, double fallback) {
    if (raw == null) return fallback;
    final t = raw.trim();
    if (t.isEmpty) return fallback;
    if (t.endsWith('%')) {
      final n = double.tryParse(t.substring(0, t.length - 1));
      return (n ?? fallback * 100) / 100.0;
    }
    return double.tryParse(t) ?? fallback;
  }

  SvgFilter? _parseFilter(XmlElement el) {
    final id = el.getAttribute('id');
    if (id == null) {
      _log.warn('parse.filter', 'filter without id; skipping');
      return null;
    }
    final prims = <SvgFilterPrimitive>[];
    for (final child in el.childElements) {
      final p = _parseFilterPrimitive(child);
      if (p != null) prims.add(p);
    }
    return SvgFilter(id: id, primitives: prims);
  }

  SvgFilterPrimitive? _parseFilterPrimitive(XmlElement el) {
    switch (el.localName) {
      case 'feGaussianBlur':
        final stdRaw = el.getAttribute('stdDeviation') ?? '0';
        final std = double.tryParse(stdRaw.split(RegExp(r'\s+')).first) ?? 0;
        SvgAnimate? anim;
        for (final c in el.childElements.where(_isAnimationTag)) {
          final n = _animations.parse(c, logger: _log);
          if (n is SvgAnimate && n.attributeName == 'stdDeviation') {
            anim = n;
          }
        }
        return SvgFilterGaussianBlur(
          stdDeviation: std,
          stdDeviationAnim: anim,
        );
      case 'feColorMatrix':
        final type = el.getAttribute('type') ?? 'matrix';
        if (type != 'saturate') {
          _log.warn('parse.filter',
              'feColorMatrix type not supported → skipping',
              fields: {'type': type});
          return null;
        }
        final values = double.tryParse(el.getAttribute('values') ?? '1') ?? 1;
        SvgAnimate? anim;
        for (final c in el.childElements.where(_isAnimationTag)) {
          final n = _animations.parse(c, logger: _log);
          if (n is SvgAnimate && n.attributeName == 'values') anim = n;
        }
        return SvgFilterColorMatrix(
          kind: SvgColorMatrixKind.saturate,
          values: values,
          valuesAnim: anim,
        );
      case 'feComponentTransfer':
        return _parseComponentTransfer(el);
      case 'feFuncR':
      case 'feFuncG':
      case 'feFuncB':
      case 'feFuncA':
        // Child of feComponentTransfer — handled by _parseComponentTransfer.
        // Standalone (outside a container) is malformed SVG.
        _log.warn('parse.filter',
            'feFunc* outside feComponentTransfer → skipping',
            fields: {'tag': el.localName});
        return null;
      default:
        _log.warn('parse.filter', 'unsupported filter primitive',
            fields: {'tag': el.localName});
        return null;
    }
  }

  SvgFilterPrimitive? _parseComponentTransfer(XmlElement el) {
    double? r, g, b;
    SvgAnimate? rAnim, gAnim, bAnim;
    for (final child in el.childElements) {
      switch (child.localName) {
        case 'feFuncR':
        case 'feFuncG':
        case 'feFuncB':
          final type = child.getAttribute('type') ?? 'identity';
          if (type != 'linear' && type != 'identity') {
            _log.warn('parse.filter',
                'feFunc* type not supported → ignoring channel',
                fields: {'tag': child.localName, 'type': type});
            continue;
          }
          final slopeRaw = child.getAttribute('slope');
          final slope =
              slopeRaw == null ? null : double.tryParse(slopeRaw.trim());
          SvgAnimate? anim;
          for (final c in child.childElements.where(_isAnimationTag)) {
            final n = _animations.parse(c, logger: _log);
            if (n is SvgAnimate && n.attributeName == 'slope') anim = n;
          }
          switch (child.localName) {
            case 'feFuncR':
              r = slope;
              rAnim = anim;
            case 'feFuncG':
              g = slope;
              gAnim = anim;
            case 'feFuncB':
              b = slope;
              bAnim = anim;
          }
        case 'feFuncA':
          // Alpha channel slope is modelled elsewhere (opacity). Ignore here.
          break;
      }
    }
    if (r == null && g == null && b == null &&
        rAnim == null && gAnim == null && bAnim == null) {
      _log.warn('parse.filter',
          'feComponentTransfer without recognised slopes → skipping');
      return null;
    }
    return SvgFilterComponentTransfer(
      slopeR: r,
      slopeG: g,
      slopeB: b,
      slopeRAnim: rAnim,
      slopeGAnim: gAnim,
      slopeBAnim: bAnim,
    );
  }

  SvgNode? _parseNode(
      XmlElement el,
      Map<String, List<SvgAnimationNode>> cssAnims,
      _CssStatics cssStatics,
      {_InheritedPaint inherited = const _InheritedPaint()}) {
    switch (el.localName) {
      case 'g':
        return _parseGroup(el, cssAnims, cssStatics, inherited: inherited);
      case 'use':
        return _parseUse(el, cssAnims, cssStatics);
      case 'image':
        return _parseImage(el, cssAnims, cssStatics);
      case 'path':
      case 'rect':
      case 'circle':
      case 'ellipse':
      case 'line':
      case 'polyline':
      case 'polygon':
        return _parseShape(el, cssAnims, cssStatics, inherited: inherited);
      default:
        _log.warn('parse.node', 'skipping unsupported element', fields: {
          'tag': el.localName,
          'id': el.getAttribute('id') ?? '',
          'reason': 'element not in MVP scope',
        });
        return null;
    }
  }

  SvgShape _parseShape(
      XmlElement el,
      Map<String, List<SvgAnimationNode>> cssAnims,
      _CssStatics cssStatics,
      {_InheritedPaint inherited = const _InheritedPaint()}) {
    final (statics, anims, amMotionPath) =
        _parseTransformsAndAnimations(el, cssAnims);
    final style = _parseInlineStyle(el.getAttribute('style'));
    final classStyle = _classStyleFor(el, cssStatics);
    final fill = style['fill'] ??
        classStyle?['fill'] ??
        el.getAttribute('fill') ??
        inherited.fill ??
        'black';
    final ownFillOpacity = double.tryParse(style['fill-opacity'] ??
            classStyle?['fill-opacity'] ??
            el.getAttribute('fill-opacity') ??
            '') ??
        1.0;
    final fillOpacity = ownFillOpacity * inherited.fillOpacity;
    final ownOpacity = double.tryParse(style['opacity'] ??
            classStyle?['opacity'] ??
            el.getAttribute('opacity') ??
            '') ??
        1.0;
    final opacity = ownOpacity * inherited.opacity;

    final strokeRaw = style['stroke'] ??
        classStyle?['stroke'] ??
        el.getAttribute('stroke');
    final strokeWidth = double.tryParse(style['stroke-width'] ??
            classStyle?['stroke-width'] ??
            el.getAttribute('stroke-width') ??
            '') ??
        1.0;
    final strokeOpacity = double.tryParse(style['stroke-opacity'] ??
            classStyle?['stroke-opacity'] ??
            el.getAttribute('stroke-opacity') ??
            '') ??
        1.0;
    final strokeLinecap = style['stroke-linecap'] ??
        classStyle?['stroke-linecap'] ??
        el.getAttribute('stroke-linecap');
    final strokeLinejoin = style['stroke-linejoin'] ??
        classStyle?['stroke-linejoin'] ??
        el.getAttribute('stroke-linejoin');
    final strokeDasharray = style['stroke-dasharray'] ??
        classStyle?['stroke-dasharray'] ??
        el.getAttribute('stroke-dasharray');
    final strokeDashoffset = double.tryParse(style['stroke-dashoffset'] ??
            classStyle?['stroke-dashoffset'] ??
            el.getAttribute('stroke-dashoffset') ??
            '') ??
        0.0;

    final kind = switch (el.localName) {
      'path' => SvgShapeKind.path,
      'rect' => SvgShapeKind.rect,
      'circle' => SvgShapeKind.circle,
      'ellipse' => SvgShapeKind.ellipse,
      'line' => SvgShapeKind.line,
      'polyline' => SvgShapeKind.polyline,
      'polygon' => SvgShapeKind.polygon,
      _ => SvgShapeKind.path,
    };

    return SvgShape(
      id: el.getAttribute('id'),
      staticTransforms: _wrapOrigin(statics, style),
      animations: anims,
      filterId: _parseFilterRef(el),
      maskId: _parseMaskRef(el),
      motionPath: _parseMotionPath(style) ?? amMotionPath,
      kind: kind,
      d: el.getAttribute('d'),
      x: _parseLength(el.getAttribute('x')) ?? 0,
      y: _parseLength(el.getAttribute('y')) ?? 0,
      width: _parseLength(el.getAttribute('width')) ?? 0,
      height: _parseLength(el.getAttribute('height')) ?? 0,
      cx: _parseLength(el.getAttribute('cx')) ?? 0,
      cy: _parseLength(el.getAttribute('cy')) ?? 0,
      r: _parseLength(el.getAttribute('r')) ?? 0,
      rx: _parseLength(el.getAttribute('rx')) ?? 0,
      ry: _parseLength(el.getAttribute('ry')) ?? 0,
      x1: _parseLength(el.getAttribute('x1')) ?? 0,
      y1: _parseLength(el.getAttribute('y1')) ?? 0,
      x2: _parseLength(el.getAttribute('x2')) ?? 0,
      y2: _parseLength(el.getAttribute('y2')) ?? 0,
      points: _parsePoints(el.getAttribute('points')),
      fill: fill,
      fillOpacity: fillOpacity,
      opacity: opacity,
      stroke: strokeRaw,
      strokeWidth: strokeWidth,
      strokeOpacity: strokeOpacity,
      strokeLinecap: strokeLinecap,
      strokeLinejoin: strokeLinejoin,
      strokeDasharray: strokeDasharray,
      strokeDashoffset: strokeDashoffset,
    );
  }

  /// `style="a: b; c: d"` → `{a: b, c: d}`. Semicolons inside balanced
  /// parens (e.g. `offset-path: path('M 0 0; Z')`) stay attached to their
  /// declaration; the split is only on top-level semicolons. Values keep
  /// their case — CSS identifiers are case-insensitive but `path('...')`
  /// payloads are not.
  Map<String, String> _parseInlineStyle(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, String>{};
    final decls = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
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
    for (final decl in decls) {
      final colon = decl.indexOf(':');
      if (colon < 0) continue;
      final k = decl.substring(0, colon).trim().toLowerCase();
      final v = decl.substring(colon + 1).trim();
      if (k.isNotEmpty) out[k] = v;
    }
    return out;
  }

  /// Reads CSS Motion Path declarations from an inline style map. Recognises
  /// `offset-path: path('M...')` (quotes optional) and
  /// `offset-rotate: auto | reverse | Ndeg`. Returns `null` when no
  /// `offset-path` is present or its value is unsupported (e.g. `ray(...)`,
  /// `url(#id)` — not in MVP scope).
  SvgMotionPath? _parseMotionPath(Map<String, String> style) {
    final raw = style['offset-path'];
    if (raw == null) return null;
    final t = raw.trim();
    if (t == 'none') return null;
    if (!t.startsWith('path(')) {
      _log.warn('parse.motion-path',
          'offset-path value not supported → ignoring',
          fields: {'value': raw});
      return null;
    }
    final open = t.indexOf('(');
    final close = t.lastIndexOf(')');
    if (open < 0 || close <= open) return null;
    var body = t.substring(open + 1, close).trim();
    if ((body.startsWith("'") && body.endsWith("'")) ||
        (body.startsWith('"') && body.endsWith('"'))) {
      body = body.substring(1, body.length - 1);
    }
    if (body.isEmpty) return null;
    return SvgMotionPath(
      pathData: body,
      rotate: _parseMotionRotate(style['offset-rotate']),
    );
  }

  /// CSS `transform-origin: Xunit Yunit`. M applied around (ox, oy) is
  /// `T(ox,oy) · M · T(-ox,-oy)` — wraps existing static transforms when
  /// the origin is non-zero. Supports `Npx` and unitless numbers; `%` and
  /// keywords (`center`/`left`/...) require bbox and are logged + skipped.
  (double, double)? _parseTransformOrigin(Map<String, String> style) {
    final raw = style['transform-origin'];
    if (raw == null) return null;
    final parts = raw.trim().split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    double? one(String t) {
      final m = RegExp(r'^([-+]?(?:\d+\.\d*|\.\d+|\d+))(px)?$').firstMatch(t);
      if (m == null) return null;
      return double.tryParse(m.group(1)!);
    }
    final x = one(parts[0]);
    final y = parts.length > 1 ? one(parts[1]) : x;
    if (x == null || y == null) {
      _log.warn('parse.transform-origin',
          'transform-origin with unsupported units → ignoring',
          fields: {'value': raw});
      return null;
    }
    return (x, y);
  }

  List<SvgStaticTransform> _wrapOrigin(
      List<SvgStaticTransform> statics, Map<String, String> style) {
    if (statics.isEmpty) return statics;
    final origin = _parseTransformOrigin(style);
    if (origin == null) return statics;
    final (ox, oy) = origin;
    if (ox == 0 && oy == 0) return statics;
    return [
      SvgStaticTransform(
          kind: SvgTransformKind.translate, values: [ox, oy]),
      ...statics,
      SvgStaticTransform(
          kind: SvgTransformKind.translate, values: [-ox, -oy]),
    ];
  }

  SvgMotionRotate _parseMotionRotate(String? raw) {
    if (raw == null) return const SvgMotionRotate.auto();
    final t = raw.trim();
    if (t.isEmpty || t == 'auto') return const SvgMotionRotate.auto();
    if (t == 'reverse' || t == 'auto reverse') {
      return const SvgMotionRotate.reverse();
    }
    final m = RegExp(
      r'^([-+]?(?:\d+\.\d*|\.\d+|\d+))\s*(deg|rad|turn|grad)?$',
    ).firstMatch(t);
    if (m == null) {
      _log.warn('parse.motion-path',
          'offset-rotate value not parseable → auto fallback',
          fields: {'value': raw});
      return const SvgMotionRotate.auto();
    }
    final v = double.tryParse(m.group(1)!) ?? 0;
    final deg = switch (m.group(2)) {
      'rad' => v * 180.0 / 3.141592653589793,
      'turn' => v * 360.0,
      'grad' => v * 0.9,
      _ => v,
    };
    return SvgMotionRotate.fixed(deg);
  }

  List<List<double>> _parsePoints(String? raw) {
    if (raw == null) return const [];
    final nums = raw
        .split(RegExp(r'[ ,]+'))
        .where((s) => s.isNotEmpty)
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    final out = <List<double>>[];
    for (var i = 0; i + 1 < nums.length; i += 2) {
      out.add([nums[i], nums[i + 1]]);
    }
    return out;
  }

  SvgGroup _parseGroup(
      XmlElement el,
      Map<String, List<SvgAnimationNode>> cssAnims,
      _CssStatics cssStatics,
      {_InheritedPaint inherited = const _InheritedPaint()}) {
    final (statics, anims, amMotionPath) =
        _parseTransformsAndAnimations(el, cssAnims);
    final style = _parseInlineStyle(el.getAttribute('style'));
    final classStyle = _classStyleFor(el, cssStatics);
    final ownFill =
        style['fill'] ?? classStyle?['fill'] ?? el.getAttribute('fill');
    final ownFillOp = double.tryParse(style['fill-opacity'] ??
        classStyle?['fill-opacity'] ??
        el.getAttribute('fill-opacity') ??
        '');
    final ownOp = double.tryParse(style['opacity'] ??
        classStyle?['opacity'] ??
        el.getAttribute('opacity') ??
        '');
    final childInherited = _InheritedPaint(
      fill: ownFill ?? inherited.fill,
      fillOpacity: (ownFillOp ?? 1.0) * inherited.fillOpacity,
      opacity: (ownOp ?? 1.0) * inherited.opacity,
    );
    final children = <SvgNode>[];
    for (final child in el.childElements) {
      if (_isAnimationTag(child)) continue;
      if (_isDecorativeSkip(child.localName)) continue;
      final n = _parseNode(child, cssAnims, cssStatics,
          inherited: childInherited);
      if (n != null) children.add(n);
    }
    return SvgGroup(
      id: el.getAttribute('id'),
      staticTransforms: _wrapOrigin(statics, style),
      animations: anims,
      filterId: _parseFilterRef(el),
      maskId: _parseMaskRef(el),
      motionPath: _parseMotionPath(style) ?? amMotionPath,
      children: children,
      displayNone: el.getAttribute('display') == 'none',
    );
  }

  SvgUse? _parseUse(
      XmlElement el,
      Map<String, List<SvgAnimationNode>> cssAnims,
      _CssStatics cssStatics) {
    final href = el.getAttribute('xlink:href') ?? el.getAttribute('href');
    if (href == null || !href.startsWith('#')) {
      _log.warn('parse.use', 'skipping <use> with missing/non-local href',
          fields: {'href': href ?? '(null)'});
      return null;
    }
    final (statics, anims, amMotionPath) =
        _parseTransformsAndAnimations(el, cssAnims);
    final style = _parseInlineStyle(el.getAttribute('style'));
    return SvgUse(
      id: el.getAttribute('id'),
      hrefId: href.substring(1),
      staticTransforms: _wrapOrigin(statics, style),
      animations: anims,
      filterId: _parseFilterRef(el),
      maskId: _parseMaskRef(el),
      motionPath: _parseMotionPath(style) ?? amMotionPath,
      width: _parseLength(el.getAttribute('width')),
      height: _parseLength(el.getAttribute('height')),
    );
  }

  SvgImage? _parseImage(
      XmlElement el,
      Map<String, List<SvgAnimationNode>> cssAnims,
      _CssStatics cssStatics) {
    final href = el.getAttribute('xlink:href') ?? el.getAttribute('href');
    if (href == null) {
      _log.warn('parse.image', 'skipping <image> without href',
          fields: {'id': el.getAttribute('id') ?? ''});
      return null;
    }
    final width = _parseLength(el.getAttribute('width')) ?? 0;
    final height = _parseLength(el.getAttribute('height')) ?? 0;
    final (statics, anims, amMotionPath) =
        _parseTransformsAndAnimations(el, cssAnims);
    final style = _parseInlineStyle(el.getAttribute('style'));
    return SvgImage(
      id: el.getAttribute('id'),
      href: href,
      width: width,
      height: height,
      staticTransforms: _wrapOrigin(statics, style),
      animations: anims,
      filterId: _parseFilterRef(el),
      maskId: _parseMaskRef(el),
      motionPath: _parseMotionPath(style) ?? amMotionPath,
    );
  }

  String? _parseFilterRef(XmlElement el) {
    return _parseUrlRef(el.getAttribute('filter'));
  }

  String? _parseMaskRef(XmlElement el) {
    return _parseUrlRef(el.getAttribute('mask'));
  }

  String? _parseUrlRef(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
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

  (List<SvgStaticTransform>, List<SvgAnimationNode>, SvgMotionPath?)
      _parseTransformsAndAnimations(
          XmlElement el, Map<String, List<SvgAnimationNode>> cssAnims) {
    final attrStatics =
        _transforms.parse(el.getAttribute('transform'), logger: _log);
    final statics = <SvgStaticTransform>[...attrStatics];
    final anims = <SvgAnimationNode>[];
    SvgMotionPath? motionPath;
    for (final child in el.childElements) {
      if (!_isAnimationTag(child)) continue;
      if (child.localName == 'animateMotion') {
        final extracted = _extractAnimateMotion(child);
        if (extracted != null) {
          if (extracted.$1 != null) motionPath ??= extracted.$1;
          anims.add(extracted.$2);
        }
        continue;
      }
      final n = _animations.parse(child, logger: _log, parent: el);
      if (n != null) anims.add(n);
    }
    final id = el.getAttribute('id');
    if (id != null) {
      final fromCss = cssAnims[id];
      if (fromCss != null && fromCss.isNotEmpty) {
        anims.addAll(fromCss);
      }
      final fromSvgator = _svgatorStatics[id];
      if (fromSvgator != null && fromSvgator.isNotEmpty) {
        statics.addAll(fromSvgator);
      }
    }
    return (statics, anims, motionPath);
  }

  /// Converts a SMIL `<animateMotion>` into either:
  /// - `(SvgMotionPath, SvgAnimate(offset-distance))` when a `path="..."`
  ///   attribute is present — the CSS Motion Path pipeline then samples the
  ///   path and produces translate/rotate keyframes.
  /// - `(null, SvgAnimateTransform(translate))` when only `values=` or
  ///   `from`/`to`/`by` point lists are provided — the element is translated
  ///   directly through the listed coordinates.
  ///
  /// MVP scope: honours `dur`, `repeatCount`, `rotate="auto"|"auto-reverse"|<deg>`,
  /// `keyPoints`/`keyTimes` (path form). `<mpath xlink:href="#id">` child is
  /// not yet resolved.
  (SvgMotionPath?, SvgAnimationNode)? _extractAnimateMotion(XmlElement el) {
    final path = el.getAttribute('path');
    final valuesRaw = el.getAttribute('values');
    final fromRaw = el.getAttribute('from');
    final toRaw = el.getAttribute('to');
    final byRaw = el.getAttribute('by');

    final durRaw = el.getAttribute('dur');
    double dur;
    if (durRaw == null) {
      _log.warn('parse.anim', 'skipping <animateMotion> without dur',
          fields: {'path': path ?? valuesRaw ?? ''});
      return null;
    }
    try {
      dur = _parseAnimateMotionDuration(durRaw);
    } on FormatException catch (e) {
      _log.warn('parse.anim', 'skipping <animateMotion> with invalid dur',
          fields: {'dur': durRaw, 'err': e.message});
      return null;
    }
    final repeat = (el.getAttribute('repeatCount') ?? '') == 'indefinite';
    final additive = el.getAttribute('additive') == 'sum'
        ? SvgAnimationAdditive.sum
        : SvgAnimationAdditive.replace;

    if (path != null) {
      final rotate = _parseAnimateMotionRotate(el.getAttribute('rotate'));
      final keyPointsRaw = el.getAttribute('keyPoints');
      final keyTimesRaw = el.getAttribute('keyTimes');
      List<String> offsetValues;
      List<double> offsetKeyTimes;
      if (keyPointsRaw != null && keyTimesRaw != null) {
        final pts = keyPointsRaw
            .split(';')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        final kts = keyTimesRaw
            .split(';')
            .map((s) => double.tryParse(s.trim()) ?? 0.0)
            .toList();
        if (pts.length == kts.length && pts.isNotEmpty) {
          offsetValues = pts.map((p) {
            final v = double.tryParse(p) ?? 0;
            return '${(v * 100).toStringAsFixed(2)}%';
          }).toList();
          offsetKeyTimes = kts;
        } else {
          offsetValues = const ['0%', '100%'];
          offsetKeyTimes = const [0, 1];
        }
      } else {
        offsetValues = const ['0%', '100%'];
        offsetKeyTimes = const [0, 1];
      }
      final anim = SvgAnimate(
        attributeName: 'offset-distance',
        durSeconds: dur,
        repeatIndefinite: repeat,
        additive: additive,
        keyframes: SvgKeyframes(
          keyTimes: offsetKeyTimes,
          values: offsetValues,
          calcMode: SvgAnimationCalcMode.linear,
        ),
      );
      return (SvgMotionPath(pathData: path, rotate: rotate), anim);
    }

    // Point-list form: values="x,y; x,y" (or from/to/by sugar).
    final points = _resolveMotionValues(valuesRaw, fromRaw, toRaw, byRaw);
    if (points == null || points.length < 2) {
      _log.warn('parse.anim',
          'skipping <animateMotion>: no path, values, or from/to/by',
          fields: {'id': el.getAttribute('id') ?? ''});
      return null;
    }
    final keyTimesRaw = el.getAttribute('keyTimes');
    List<double> keyTimes;
    if (keyTimesRaw != null) {
      final parsed = keyTimesRaw
          .split(';')
          .map((s) => double.tryParse(s.trim()) ?? 0.0)
          .toList();
      keyTimes = parsed.length == points.length
          ? parsed
          : _implicitKeyTimes(points.length);
    } else {
      keyTimes = _implicitKeyTimes(points.length);
    }
    final translate = SvgAnimateTransform(
      kind: SvgTransformKind.translate,
      durSeconds: dur,
      repeatIndefinite: repeat,
      additive: additive,
      keyframes: SvgKeyframes(
        keyTimes: keyTimes,
        values: points,
        calcMode: SvgAnimationCalcMode.linear,
      ),
    );
    return (null, translate);
  }

  /// Resolves SMIL animateMotion's point list from `values`, or synthesizes
  /// one from `from`/`to`/`by`. Every returned string is `"x,y"` so the
  /// downstream SvgAnimateTransform(translate) serializer sees a uniform
  /// format. Returns null if nothing usable was provided.
  List<String>? _resolveMotionValues(
      String? valuesRaw, String? fromRaw, String? toRaw, String? byRaw) {
    if (valuesRaw != null) {
      final out = <String>[];
      for (final seg in valuesRaw.split(';')) {
        final t = seg.trim();
        if (t.isEmpty) continue;
        final nums = t.split(RegExp(r'[ ,]+')).where((s) => s.isNotEmpty).toList();
        if (nums.length >= 2) out.add('${nums[0]},${nums[1]}');
      }
      return out.isEmpty ? null : out;
    }
    String? fmt(String? pair) {
      if (pair == null) return null;
      final nums =
          pair.trim().split(RegExp(r'[ ,]+')).where((s) => s.isNotEmpty).toList();
      if (nums.length < 2) return null;
      return '${nums[0]},${nums[1]}';
    }

    final from = fmt(fromRaw) ?? '0,0';
    final to = fmt(toRaw);
    if (to != null) return [from, to];
    final by = fmt(byRaw);
    if (by != null) {
      final f = from.split(',').map(double.tryParse).toList();
      final b = by.split(',').map(double.tryParse).toList();
      if (f.length == 2 && b.length == 2 &&
          f[0] != null && f[1] != null && b[0] != null && b[1] != null) {
        return [from, '${f[0]! + b[0]!},${f[1]! + b[1]!}'];
      }
    }
    return null;
  }

  List<double> _implicitKeyTimes(int n) {
    if (n <= 1) return const [0];
    return List.generate(n, (i) => i / (n - 1));
  }

  SvgMotionRotate _parseAnimateMotionRotate(String? raw) {
    if (raw == null) return const SvgMotionRotate.fixed(0);
    final t = raw.trim();
    if (t == 'auto') return const SvgMotionRotate.auto();
    if (t == 'auto-reverse') return const SvgMotionRotate.reverse();
    final n = double.tryParse(t.replaceFirst(RegExp(r'(deg)$'), ''));
    if (n != null) return SvgMotionRotate.fixed(n);
    return const SvgMotionRotate.fixed(0);
  }

  double _parseAnimateMotionDuration(String raw) {
    final trimmed = raw.trim();
    if (trimmed.endsWith('ms')) {
      return double.parse(trimmed.substring(0, trimmed.length - 2)) / 1000.0;
    }
    if (trimmed.endsWith('s')) {
      return double.parse(trimmed.substring(0, trimmed.length - 1));
    }
    return double.parse(trimmed);
  }

  bool _isAnimationTag(XmlElement el) =>
      el.localName == 'animate' ||
      el.localName == 'animateTransform' ||
      el.localName == 'animateMotion' ||
      el.localName == 'set';

  /// Elements we silently skip instead of throwing: either purely decorative
  /// metadata (title/desc/metadata), document-level wrappers that don't
  /// contribute renderable geometry on their own (style/filter), or masking
  /// primitives we don't yet implement. Skipping preserves the rest of the
  /// document for the MVP image+SMIL pipeline.
  bool _isDecorativeSkip(String tag) => const {
        'style',
        'title',
        'desc',
        'metadata',
        'filter',
        'clipPath',
        // NOTE: 'mask' intentionally NOT here — it's routed to _parseMask
        // and stored in SvgDefs.masks, then resolved by the mapper as a
        // Lottie track matte. Leaving it in the skip set silently dropped
        // clipping regions and caused visible content to bleed through.
        'pattern',
        'marker',
        'symbol',
        'linearGradient',
        'radialGradient',
      }.contains(tag);

  /// Builds `class → [ids]` map for elements that carry both a `class` and
  /// an `id` attribute. The CSS parser uses this to expand `.cls { ... }`
  /// selectors into the same id-keyed animation map it produces for `#id`.
  /// Elements with a class but no id can't be targeted individually downstream
  /// — they're silently ignored here.
  /// Merges per-class styles (in declaration order from the element's
  /// `class=` attribute) with per-id styles (if any). `#id` rules win over
  /// `.class` rules per CSS specificity; multiple classes compose
  /// left-to-right, later classes overriding earlier ones.
  Map<String, String>? _classStyleFor(XmlElement el, _CssStatics statics) {
    if (statics.byId.isEmpty && statics.byClass.isEmpty) return null;
    final out = <String, String>{};
    final classRaw = el.getAttribute('class');
    if (classRaw != null && classRaw.trim().isNotEmpty) {
      for (final cls in classRaw.trim().split(RegExp(r'\s+'))) {
        final styles = statics.byClass[cls];
        if (styles != null) out.addAll(styles);
      }
    }
    final id = el.getAttribute('id');
    if (id != null) {
      final idStyles = statics.byId[id];
      if (idStyles != null) out.addAll(idStyles);
    }
    return out.isEmpty ? null : out;
  }

  Map<String, List<String>> _buildClassIndex(XmlElement root) {
    final out = <String, List<String>>{};
    for (final el in root.descendants.whereType<XmlElement>()) {
      final id = el.getAttribute('id');
      if (id == null) continue;
      final classRaw = el.getAttribute('class');
      if (classRaw == null || classRaw.trim().isEmpty) continue;
      for (final cls in classRaw.trim().split(RegExp(r'\s+'))) {
        if (cls.isEmpty) continue;
        (out[cls] ??= <String>[]).add(id);
      }
    }
    return out;
  }

  double? _parseLength(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    // strip common units
    final stripped = t.replaceFirst(RegExp(r'(px|pt|em|rem|%)$'), '');
    return double.tryParse(stripped);
  }

  SvgViewBox _parseViewBox(String? raw, double? w, double? h) {
    if (raw == null) {
      return SvgViewBox(0, 0, w ?? 0, h ?? 0);
    }
    final parts = raw
        .trim()
        .split(RegExp(r'[ ,]+'))
        .where((s) => s.isNotEmpty)
        .map(double.parse)
        .toList();
    if (parts.length != 4) {
      throw ParseException('viewBox expects 4 numbers, got $raw');
    }
    return SvgViewBox(parts[0], parts[1], parts[2], parts[3]);
  }
}

/// Presentation attributes inherited from ancestor `<g>` elements. SVG
/// cascades `fill`, `fill-opacity`, and `opacity` down the tree; only shapes
/// actually emit them, so we collect them at group boundaries and apply at
/// the leaf shape. Opacity channels multiply through the chain.
class _InheritedPaint {
  const _InheritedPaint({
    this.fill,
    this.fillOpacity = 1.0,
    this.opacity = 1.0,
  });
  final String? fill;
  final double fillOpacity;
  final double opacity;
}

/// Static CSS declarations harvested from `<style>` blocks. Split by
/// selector kind so `<path class="x">` with no `id=` still resolves rules
/// from `.x{...}` (our class index only sees elements with both id and
/// class). `byId` takes precedence over `byClass` in the cascade — matching
/// CSS specificity (`#id` > `.class`).
class _CssStatics {
  const _CssStatics({
    this.byId = const {},
    this.byClass = const {},
  });
  final Map<String, Map<String, String>> byId;
  final Map<String, Map<String, String>> byClass;
}
