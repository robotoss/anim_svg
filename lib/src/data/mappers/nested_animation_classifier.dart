import '../../domain/entities/svg_animation.dart';

/// Decides how to express a nested chain of animated `<g>` groups in
/// Lottie. Two strategies:
///
/// - **Parenting** (preferred): each ancestor becomes its own Lottie
///   layer (null-layer / `ty:3`) carrying its animateTransforms; the
///   child layer references it via the Lottie `parent` field. The
///   hierarchy stays shallow at render time and every ancestor animates
///   in its own time domain (set by its own `dur`/`repeatIndefinite`).
///   Preconditions:
///     - Equal `durSeconds` and `repeatIndefinite` flags across the
///       whole chain (Lottie layers share the top-level `outPoint`; if
///       the cycles don't align, a child with a shorter `dur` would
///       desynchronise because Lottie does not expose per-layer time
///       warping). `SvgAnimationNormalizer` already folds CSS
///       `animation-direction` into keyframes, so only numeric `dur`
///       matters here.
///     - Chain depth ≤ `maxDepth` (thorvg has a soft performance cliff
///       on deep parent chains).
///
/// - **Bake** (fallback): collapse the chain into per-frame samples on
///   the leaf. Supported today only for a single animated ancestor; the
///   mapper's existing `_buildBakedTransform` handles it. Documented as a
///   known limitation for mismatched-dur multi-level chains.
class NestedAnimationClassifier {
  const NestedAnimationClassifier({this.maxDepth = 6, this.durEpsilon = 1e-3});

  /// Maximum depth of a parenting chain. Chains deeper than this fall
  /// back to bake even when durations agree. thorvg's Lottie renderer
  /// starts degrading past ~8 parents; we leave headroom for the leaf
  /// and an outer static-transform carrier if ever added.
  final int maxDepth;

  /// Tolerance for comparing `durSeconds` across ancestors. AE/Figma
  /// exports sometimes round to 3 decimal places.
  final double durEpsilon;

  /// Returns true when the given chain of groups (root→leaf order) can
  /// be expressed as a Lottie parenting chain: all entries animate with
  /// the same `durSeconds` and matching `repeatIndefinite`.
  bool canChainParent(List<ChainEntry> chain) {
    if (chain.isEmpty) return false;
    if (chain.length > maxDepth) return false;
    final dur = chain.first.durSeconds;
    final loop = chain.first.repeatIndefinite;
    for (final e in chain) {
      if ((e.durSeconds - dur).abs() > durEpsilon) return false;
      if (e.repeatIndefinite != loop) return false;
    }
    return true;
  }
}

/// Minimal snapshot of an animated group needed by the classifier.
class ChainEntry {
  const ChainEntry({
    required this.durSeconds,
    required this.repeatIndefinite,
    required this.transformAnims,
  });
  final double durSeconds;
  final bool repeatIndefinite;
  final List<SvgAnimateTransform> transformAnims;
}
