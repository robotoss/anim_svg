import 'package:meta/meta.dart';

@immutable
class LottieDoc {
  const LottieDoc({
    this.version = '5.7.0',
    required this.frameRate,
    required this.inPoint,
    required this.outPoint,
    required this.width,
    required this.height,
    required this.assets,
    required this.layers,
  });

  final String version;
  final double frameRate;
  final double inPoint;
  final double outPoint;
  final double width;
  final double height;
  final List<LottieAsset> assets;
  final List<LottieLayer> layers;
}

enum LottieShapeKind { rect, ellipse, path }

/// An item inside a Lottie shape layer. Shape items are grouped: typically
/// one [LottieShapeGeometry] (the outline) paired with a [LottieShapeFill]
/// (the colour). See `ty:"gr"` in the Lottie schema.
@immutable
sealed class LottieShapeItem {
  const LottieShapeItem();
}

@immutable
class LottieShapeGeometry extends LottieShapeItem {
  const LottieShapeGeometry({
    required this.kind,
    this.vertices = const [],
    this.inTangents = const [],
    this.outTangents = const [],
    this.closed = true,
    this.rectPosition = const [0, 0],
    this.rectSize = const [0, 0],
    this.rectRoundness = 0,
    this.ellipsePosition = const [0, 0],
    this.ellipseSize = const [0, 0],
    this.pathKeyframes,
  });

  final LottieShapeKind kind;

  // ty:"sh" — path
  final List<List<double>> vertices;
  final List<List<double>> inTangents;
  final List<List<double>> outTangents;
  final bool closed;

  // ty:"rc" — rect
  final List<double> rectPosition;
  final List<double> rectSize;
  final double rectRoundness;

  // ty:"el" — ellipse
  final List<double> ellipsePosition;
  final List<double> ellipseSize;

  /// When non-null, the path is animated (SVG `<animate attributeName="d">`).
  /// Emitted as Lottie `"ks":{"a":1, "k":[...]}`. All keyframes must share
  /// vertex count and `closed` flag (enforced upstream by the shape mapper).
  /// The static `vertices`/`inTangents`/`outTangents`/`closed` mirror the
  /// first keyframe so fallback consumers still see a usable shape.
  final List<LottieShapePathKeyframe>? pathKeyframes;
}

/// One keyframe of an animated Lottie `sh` shape. Mirrors the static
/// vertex/tangent triplet plus timing/easing controls.
@immutable
class LottieShapePathKeyframe {
  const LottieShapePathKeyframe({
    required this.time,
    required this.vertices,
    required this.inTangents,
    required this.outTangents,
    required this.closed,
    this.hold = false,
    this.bezierIn,
    this.bezierOut,
  });

  final double time;
  final List<List<double>> vertices;
  final List<List<double>> inTangents;
  final List<List<double>> outTangents;
  final bool closed;
  final bool hold;
  final BezierHandle? bezierIn;
  final BezierHandle? bezierOut;
}

@immutable
class LottieShapeFill extends LottieShapeItem {
  const LottieShapeFill({
    required this.color,
    this.opacity = 100,
  });

  /// Normalised RGBA in [0, 1]. Length 4.
  final List<double> color;
  final double opacity;
}

/// Lottie stroke item (`ty:"st"`). Drawn alongside [LottieShapeFill] in the
/// shape group. SVG's `stroke-dashoffset` animation is NOT expressed here —
/// it becomes a [LottieShapeTrimPath] later in the item list.
@immutable
class LottieShapeStroke extends LottieShapeItem {
  const LottieShapeStroke({
    required this.color,
    this.opacity = 100,
    this.width = 1,
    this.lineCap = 1,
    this.lineJoin = 1,
    this.miterLimit = 4,
  });

  /// Normalised RGBA in [0, 1]. Length 4.
  final List<double> color;
  final double opacity;
  final double width;

  /// `1` = butt, `2` = round, `3` = square (Lottie `lc`).
  final int lineCap;

  /// `1` = miter, `2` = round, `3` = bevel (Lottie `lj`).
  final int lineJoin;
  final double miterLimit;
}

/// Lottie Trim Paths modifier (`ty:"tm"`). Placed at the END of a shape
/// group's items; it trims all preceding path geometries in that group to
/// the `start`/`end` percentage range. SVG's `stroke-dashoffset` animation on
/// a path with `stroke-dasharray=L` maps to an animated `end = (1 -
/// dashoffset/L) * 100` while `start` stays 0.
@immutable
class LottieShapeTrimPath extends LottieShapeItem {
  const LottieShapeTrimPath({
    required this.start,
    required this.end,
    required this.offset,
  });

  /// 0..100 percentage.
  final LottieScalarProp start;

  /// 0..100 percentage.
  final LottieScalarProp end;

  /// 0..360 degrees. Rotational start offset along the path.
  final LottieScalarProp offset;
}

enum LottieGradientKind { linear, radial }

/// Lottie gradient fill (`ty:"gf"`). The gradient data (`g.k`) is either a
/// single flat stop array (static) or a keyframe sequence (animated offsets).
/// Each flat entry encodes colour stops first as `[o,r,g,b]*n`, optionally
/// followed by opacity stops `[o,a]*m`.
@immutable
class LottieShapeGradientFill extends LottieShapeItem {
  const LottieShapeGradientFill({
    required this.kind,
    required this.colorStopCount,
    required this.startPoint,
    required this.endPoint,
    required this.stops,
    this.opacity = 100,
  });

  final LottieGradientKind kind;
  final int colorStopCount;
  final List<double> startPoint;
  final List<double> endPoint;

  /// Either a single entry (static) or N keyframes (animated). Each entry is
  /// the flat gradient array.
  final LottieGradientStops stops;
  final double opacity;
}

@immutable
sealed class LottieGradientStops {
  const LottieGradientStops();
}

@immutable
class LottieGradientStopsStatic extends LottieGradientStops {
  const LottieGradientStopsStatic(this.values);
  final List<double> values;
}

@immutable
class LottieGradientStopsAnimated extends LottieGradientStops {
  const LottieGradientStopsAnimated(this.keyframes);
  final List<LottieGradientKeyframe> keyframes;
}

@immutable
class LottieGradientKeyframe {
  const LottieGradientKeyframe({
    required this.time,
    required this.values,
    this.hold = false,
  });

  final double time;
  final List<double> values;
  final bool hold;
}

@immutable
class LottieAsset {
  const LottieAsset({
    required this.id,
    required this.width,
    required this.height,
    required this.dataUri,
  });

  final String id;
  final double width;
  final double height;

  /// Embedded data URI (Lottie: `p` with `e:1`).
  final String dataUri;
}

@immutable
sealed class LottieLayer {
  const LottieLayer({
    required this.index,
    required this.name,
    required this.transform,
    required this.inPoint,
    required this.outPoint,
    this.effects = const [],
    this.parent,
    this.td,
    this.tt,
  });

  final int index;
  final String name;
  final LottieTransform transform;
  final double inPoint;
  final double outPoint;
  final List<LottieEffect> effects;

  /// Lottie `parent` field: the `ind` of the layer whose transform is
  /// inherited by this one. `null` → no parenting. Used to implement the
  /// CSS "nested animated groups" hybrid (see `AnimationNestingClassifier`):
  /// equal-dur chains are expressed as null-layer parents instead of
  /// baking the whole transform stack into the leaf.
  final int? parent;

  /// Lottie track-matte source flag (`td`). `1` means "this layer is a
  /// matte source — do not render it visibly, feed its alpha/luma into the
  /// next layer below". Emitted for `<mask>` contents.
  final int? td;

  /// Lottie track-matte target flag (`tt`). Values: `1`=alpha, `2`=luma,
  /// `3`=alpha inverted, `4`=luma inverted. Set on the masked target layer
  /// whose source sits immediately above it. Emitted for nodes carrying
  /// `mask="url(#id)"`.
  final int? tt;
}

@immutable
sealed class LottieEffect {
  const LottieEffect();
}

/// Gaussian blur effect (`ty:29`). `blurriness` is the pixel radius, mapped
/// from SVG `stdDeviation` (~2× factor).
@immutable
class LottieBlurEffect extends LottieEffect {
  const LottieBlurEffect({required this.blurriness});
  final LottieScalarProp blurriness;
}

/// Brightness & Contrast effect (`ty:22`, mn `ADBE Brightness & Contrast 2`).
/// Emitted from an SVG `feComponentTransfer` whose RGB slopes animate in
/// lock-step (pragmatic fallback — Lottie/thorvg have no exact equivalent
/// of per-channel linear slopes). `brightness` is a signed offset in AE
/// units where 0 = neutral; a slope of `1 + k` on all channels maps to
/// brightness `k * 100` (empirical — AE's brightness range maps roughly
/// [-150, 150] onto RGB multiplier [-0.5, 2.5]).
@immutable
class LottieBrightnessEffect extends LottieEffect {
  const LottieBrightnessEffect({required this.brightness});
  final LottieScalarProp brightness;
}

/// Hue/Saturation effect (`ty:19`, mn `ADBE HUE SATURATION`). Emitted from
/// an SVG `feColorMatrix type="saturate"`. `masterSaturation` is the AE
/// `Master Saturation` channel in AE units (range [-100, 100], 0 = neutral).
/// Mapping: SVG saturate `s` → `(s - 1) * 100` (s=1 → 0, s=2 → +100 boost,
/// s=0 → -100 full desaturation). Lottie has no native linear-saturation
/// primitive; Hue/Saturation is the closest semantic match supported by
/// thorvg/bodymovin/lottie-web.
@immutable
class LottieHueSaturationEffect extends LottieEffect {
  const LottieHueSaturationEffect({required this.masterSaturation});
  final LottieScalarProp masterSaturation;
}

/// Lottie image layer (ty:2) referencing an asset in the top-level `assets`.
@immutable
class LottieImageLayer extends LottieLayer {
  const LottieImageLayer({
    required super.index,
    required super.name,
    required super.transform,
    required super.inPoint,
    required super.outPoint,
    required this.refId,
    this.width,
    this.height,
    super.effects,
    super.parent,
    super.td,
    super.tt,
  });

  final String refId;
  final double? width;
  final double? height;
}

/// Lottie shape layer (ty:4) containing one or more shape groups.
@immutable
class LottieShapeLayer extends LottieLayer {
  const LottieShapeLayer({
    required super.index,
    required super.name,
    required super.transform,
    required super.inPoint,
    required super.outPoint,
    required this.shapes,
    super.effects,
    super.parent,
    super.td,
    super.tt,
  });

  final List<LottieShapeItem> shapes;
}

/// Lottie null-layer (ty:3). Carries only a transform; no visual output.
/// Used as a parent frame so descendant layers inherit its transform
/// (including animated channels), mirroring the SVG-side `<g>` with its
/// own animateTransforms.
@immutable
class LottieNullLayer extends LottieLayer {
  const LottieNullLayer({
    required super.index,
    required super.name,
    required super.transform,
    required super.inPoint,
    required super.outPoint,
    super.parent,
    super.td,
    super.tt,
  });
}

@immutable
class LottieTransform {
  const LottieTransform({
    required this.anchor,
    required this.position,
    required this.scale,
    required this.rotation,
    required this.opacity,
  });

  /// Anchor point (ks.a). Typically static [0,0] in MVP.
  final LottieVectorProp anchor;
  final LottieVectorProp position; // ks.p
  final LottieVectorProp scale; // ks.s (percent)
  final LottieScalarProp rotation; // ks.r (deg)
  final LottieScalarProp opacity; // ks.o (0..100)
}

@immutable
sealed class LottieVectorProp {
  const LottieVectorProp();
}

@immutable
class LottieVectorStatic extends LottieVectorProp {
  const LottieVectorStatic(this.value);
  final List<double> value;
}

@immutable
class LottieVectorAnimated extends LottieVectorProp {
  const LottieVectorAnimated(this.keyframes);
  final List<LottieVectorKeyframe> keyframes;
}

@immutable
sealed class LottieScalarProp {
  const LottieScalarProp();
}

@immutable
class LottieScalarStatic extends LottieScalarProp {
  const LottieScalarStatic(this.value);
  final double value;
}

@immutable
class LottieScalarAnimated extends LottieScalarProp {
  const LottieScalarAnimated(this.keyframes);
  final List<LottieScalarKeyframe> keyframes;
}

@immutable
class LottieVectorKeyframe {
  const LottieVectorKeyframe({
    required this.time,
    required this.start,
    this.hold = false,
    this.bezierIn,
    this.bezierOut,
  });

  final double time; // in frames
  final List<double> start; // s
  final bool hold; // h:1
  final BezierHandle? bezierIn; // i
  final BezierHandle? bezierOut; // o
}

@immutable
class LottieScalarKeyframe {
  const LottieScalarKeyframe({
    required this.time,
    required this.start,
    this.hold = false,
    this.bezierIn,
    this.bezierOut,
  });

  final double time;
  final double start;
  final bool hold;
  final BezierHandle? bezierIn;
  final BezierHandle? bezierOut;
}

@immutable
class BezierHandle {
  const BezierHandle(this.x, this.y);
  final double x;
  final double y;
}
