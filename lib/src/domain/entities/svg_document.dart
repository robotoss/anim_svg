import 'package:meta/meta.dart';

import 'svg_animation.dart';
import 'svg_motion_path.dart';
import 'svg_transform.dart';

@immutable
class SvgDocument {
  const SvgDocument({
    required this.width,
    required this.height,
    required this.viewBox,
    required this.defs,
    required this.root,
  });

  final double width;
  final double height;
  final SvgViewBox viewBox;
  final SvgDefs defs;
  final SvgGroup root;
}

@immutable
class SvgViewBox {
  const SvgViewBox(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;
}

@immutable
sealed class SvgNode {
  const SvgNode({
    required this.id,
    required this.staticTransforms,
    required this.animations,
    this.filterId,
    this.maskId,
    this.motionPath,
  });

  final String? id;
  final List<SvgStaticTransform> staticTransforms;
  final List<SvgAnimationNode> animations;

  /// When `filter="url(#id)"` is present, the local fragment id. The mapper
  /// looks this up in `SvgDefs.filters` and attaches layer effects to the
  /// corresponding Lottie layer.
  final String? filterId;

  /// When `mask="url(#id)"` is present, the local fragment id. Resolved by
  /// the mapper against `SvgDefs.masks` and emitted as a Lottie track matte
  /// (`td`/`tt`) pair.
  final String? maskId;

  /// CSS Motion Path declared in the node's inline `style`. Combined with an
  /// `offset-distance` animation (emitted by the CSS parser) to produce
  /// translate/rotate keyframes via `MotionPathResolver`.
  final SvgMotionPath? motionPath;
}

@immutable
class SvgGroup extends SvgNode {
  const SvgGroup({
    super.id,
    required super.staticTransforms,
    required super.animations,
    super.filterId,
    super.maskId,
    super.motionPath,
    required this.children,
    this.displayNone = false,
  });

  final List<SvgNode> children;
  final bool displayNone;
}

@immutable
class SvgImage extends SvgNode {
  const SvgImage({
    super.id,
    required super.staticTransforms,
    required super.animations,
    super.filterId,
    super.maskId,
    super.motionPath,
    required this.href,
    required this.width,
    required this.height,
  });

  /// Either `data:image/...;base64,...` or an external URI.
  final String href;
  final double width;
  final double height;
}

@immutable
class SvgUse extends SvgNode {
  const SvgUse({
    super.id,
    required super.staticTransforms,
    required super.animations,
    super.filterId,
    super.maskId,
    super.motionPath,
    required this.hrefId,
    this.width,
    this.height,
  });

  final String hrefId;
  final double? width;
  final double? height;
}

@immutable
class SvgDefs {
  const SvgDefs(
    this.byId, {
    this.gradients = const {},
    this.filters = const {},
    this.masks = const {},
  });
  final Map<String, SvgNode> byId;
  final Map<String, SvgGradient> gradients;
  final Map<String, SvgFilter> filters;
  final Map<String, SvgMask> masks;
}

enum SvgMaskType { luminance, alpha }

enum SvgMaskUnits { userSpaceOnUse, objectBoundingBox }

/// A paint mask in `<defs>` (or anywhere in the tree) referenced by
/// `mask="url(#id)"` from a renderable node. The mask's children are the
/// matte source: their rendered luminance (or alpha, for
/// `mask-type="alpha"`) drives the visibility of the masked subtree.
///
/// Emitted as a Lottie track-matte pair: a `td:1` invisible source layer
/// immediately above a `tt:2` (luma) or `tt:1` (alpha) target layer.
@immutable
class SvgMask {
  const SvgMask({
    required this.id,
    required this.children,
    this.type = SvgMaskType.luminance,
    this.x = -0.1,
    this.y = -0.1,
    this.width = 1.2,
    this.height = 1.2,
    this.maskUnits = SvgMaskUnits.objectBoundingBox,
    this.maskContentUnits = SvgMaskUnits.userSpaceOnUse,
  });

  final String id;
  final List<SvgNode> children;
  final SvgMaskType type;
  final double x, y, width, height;
  final SvgMaskUnits maskUnits;
  final SvgMaskUnits maskContentUnits;
}

@immutable
class SvgFilter {
  const SvgFilter({required this.id, required this.primitives});
  final String id;
  final List<SvgFilterPrimitive> primitives;
}

@immutable
sealed class SvgFilterPrimitive {
  const SvgFilterPrimitive();
}

@immutable
class SvgFilterGaussianBlur extends SvgFilterPrimitive {
  const SvgFilterGaussianBlur({
    required this.stdDeviation,
    this.stdDeviationAnim,
  });
  final double stdDeviation;
  final SvgAnimate? stdDeviationAnim;
}

@immutable
class SvgFilterColorMatrix extends SvgFilterPrimitive {
  const SvgFilterColorMatrix({
    required this.kind,
    required this.values,
    this.valuesAnim,
  });
  final SvgColorMatrixKind kind;
  final double values;
  final SvgAnimate? valuesAnim;
}

enum SvgColorMatrixKind { saturate, other }

/// SVG `<feComponentTransfer>` with linear slope children
/// (`<feFuncR type="linear" slope="N">` etc.). Brightness-pulse exports
/// (Adobe Animate / After Effects) animate the slopes on all three channels
/// in lock-step to make a sprite glow. Only `type="linear"` and the
/// optional `<animate attributeName="slope">` are modelled; `table`,
/// `gamma`, `discrete`, `identity` produce a WARN in the parser.
@immutable
class SvgFilterComponentTransfer extends SvgFilterPrimitive {
  const SvgFilterComponentTransfer({
    this.slopeR,
    this.slopeG,
    this.slopeB,
    this.slopeRAnim,
    this.slopeGAnim,
    this.slopeBAnim,
  });

  final double? slopeR;
  final double? slopeG;
  final double? slopeB;
  final SvgAnimate? slopeRAnim;
  final SvgAnimate? slopeGAnim;
  final SvgAnimate? slopeBAnim;
}

enum SvgGradientKind { linear, radial }

enum SvgGradientUnits { userSpaceOnUse, objectBoundingBox }

/// A paint server in `<defs>`. Not an `SvgNode` — gradients are referenced
/// by `fill="url(#id)"` from shapes, not placed in the render tree.
@immutable
class SvgGradient {
  const SvgGradient({
    required this.id,
    required this.kind,
    required this.stops,
    this.units = SvgGradientUnits.objectBoundingBox,
    this.x1 = 0,
    this.y1 = 0,
    this.x2 = 1,
    this.y2 = 0,
    this.cx = 0.5,
    this.cy = 0.5,
    this.r = 0.5,
    this.fx,
    this.fy,
    this.hasGradientTransform = false,
    this.gradientTransform,
  });

  final String id;
  final SvgGradientKind kind;
  final List<SvgStop> stops;
  final SvgGradientUnits units;
  // linear
  final double x1, y1, x2, y2;
  // radial
  final double cx, cy, r;
  final double? fx, fy;
  final bool hasGradientTransform;

  /// Flattened 2D affine matrix `[a, b, c, d, e, f]` (SVG order) applied to
  /// gradient control points in the gradient's native coordinate space
  /// before stops are sampled. `null` means identity.
  final List<double>? gradientTransform;
}

/// A single gradient colour stop. Offset may be animated via an
/// `<animate attributeName="offset">` child (stored in [animations]).
@immutable
class SvgStop {
  const SvgStop({
    required this.offset,
    required this.color,
    this.stopOpacity = 1.0,
    this.animations = const [],
  });

  final double offset;

  /// Raw CSS-ish color (hex, rgb(), named).
  final String color;
  final double stopOpacity;
  final List<SvgAnimationNode> animations;
}

enum SvgShapeKind {
  path,
  rect,
  circle,
  ellipse,
  line,
  polyline,
  polygon,
}

/// A geometric shape node (path/rect/circle/...). Geometry is kept in raw
/// SVG form and normalised by the shape mapper when converting to Lottie.
@immutable
class SvgShape extends SvgNode {
  const SvgShape({
    super.id,
    required super.staticTransforms,
    required super.animations,
    super.filterId,
    super.maskId,
    super.motionPath,
    required this.kind,
    this.d,
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.cx = 0,
    this.cy = 0,
    this.r = 0,
    this.rx = 0,
    this.ry = 0,
    this.x1 = 0,
    this.y1 = 0,
    this.x2 = 0,
    this.y2 = 0,
    this.points = const [],
    this.fill = 'black',
    this.fillOpacity = 1.0,
    this.opacity = 1.0,
    this.stroke,
    this.strokeWidth = 0,
    this.strokeOpacity = 1.0,
    this.strokeLinecap,
    this.strokeLinejoin,
    this.strokeDasharray,
    this.strokeDashoffset = 0,
  });

  final SvgShapeKind kind;

  /// Path `d` attribute (for `SvgShapeKind.path`).
  final String? d;

  // rect
  final double x, y, width, height;
  // circle / ellipse
  final double cx, cy, r, rx, ry;
  // line
  final double x1, y1, x2, y2;
  // polyline / polygon — flat `[[x,y], [x,y], ...]`.
  final List<List<double>> points;

  /// CSS-ish fill value. Either a named colour (`black`, `red`), `rgb(...)`,
  /// `#rrggbb` / `#rgb`, `none`, or `url(#gradient-id)`. The mapper parses
  /// this further.
  final String fill;
  final double fillOpacity;
  final double opacity;

  /// CSS-ish stroke paint value. `null` or `'none'` means no stroke is drawn.
  /// Gradients via `url(#id)` are not yet supported on strokes (fallback grey).
  final String? stroke;
  final double strokeWidth;
  final double strokeOpacity;

  /// `butt` | `round` | `square`. `null` → Lottie default (`butt` → 1).
  final String? strokeLinecap;

  /// `miter` | `round` | `bevel`. `null` → Lottie default (`miter` → 1).
  final String? strokeLinejoin;

  /// Raw SVG `stroke-dasharray`. Kept as a string because it can be a
  /// comma/space-separated list; the mapper currently only exercises the
  /// single-number form used by "draw-on" exports (`stroke-dasharray=L` paired
  /// with an animated `stroke-dashoffset L → 0`).
  final String? strokeDasharray;

  /// Static stroke-dashoffset. Animated dashoffset is expressed as a
  /// `SvgAnimate(attributeName: 'stroke-dashoffset')` in [animations].
  final double strokeDashoffset;
}
