import '../../core/errors.dart';
import '../../domain/entities/svg_document.dart';

/// Resolves `<use xlink:href="#id">` references against the document's
/// `<defs>`, returning a deep-copied tree where every [SvgUse] is replaced by
/// the referenced node (wrapped in an [SvgGroup] preserving the use's own
/// transforms and animations).
class UseFlattener {
  const UseFlattener();

  SvgDocument flatten(SvgDocument doc) {
    final root = _flattenGroup(doc.root, doc.defs, depth: 0);
    return SvgDocument(
      width: doc.width,
      height: doc.height,
      viewBox: doc.viewBox,
      defs: const SvgDefs({}), // defs are inlined now
      root: root,
    );
  }

  SvgNode _flattenNode(SvgNode node, SvgDefs defs, {required int depth}) {
    if (depth > 32) {
      throw ConversionException('use-flatten recursion too deep (>32)');
    }
    return switch (node) {
      SvgGroup() => _flattenGroup(node, defs, depth: depth),
      SvgUse() => _flattenUse(node, defs, depth: depth),
      SvgImage() => node,
      SvgShape() => node,
    };
  }

  SvgGroup _flattenGroup(SvgGroup g, SvgDefs defs, {required int depth}) {
    return SvgGroup(
      id: g.id,
      staticTransforms: g.staticTransforms,
      animations: g.animations,
      filterId: g.filterId,
      displayNone: g.displayNone,
      children: [
        for (final c in g.children) _flattenNode(c, defs, depth: depth + 1),
      ],
    );
  }

  SvgNode _flattenUse(SvgUse u, SvgDefs defs, {required int depth}) {
    final target = defs.byId[u.hrefId];
    if (target == null) {
      throw ParseException('<use> href="#${u.hrefId}" not found in <defs>');
    }
    // Recursively flatten the target so <use> chains collapse.
    var resolved = _flattenNode(target, defs, depth: depth + 1);
    // SVG quirk: <image> tags in <defs> often have no width/height — the size
    // is declared on the <use> that references them. Push the <use>'s size
    // into any zero-sized <image> inside the resolved subtree.
    if (u.width != null && u.height != null) {
      resolved = _applySize(resolved, u.width!, u.height!);
    }
    // Wrap into a group so the <use>'s own transforms/animations apply on top.
    return SvgGroup(
      id: u.id,
      staticTransforms: u.staticTransforms,
      animations: u.animations,
      filterId: u.filterId,
      children: [resolved],
    );
  }

  SvgNode _applySize(SvgNode node, double width, double height) {
    return switch (node) {
      SvgImage() => (node.width == 0 && node.height == 0)
          ? SvgImage(
              id: node.id,
              staticTransforms: node.staticTransforms,
              animations: node.animations,
              filterId: node.filterId,
              href: node.href,
              width: width,
              height: height,
            )
          : node,
      SvgGroup() => SvgGroup(
          id: node.id,
          staticTransforms: node.staticTransforms,
          animations: node.animations,
          filterId: node.filterId,
          displayNone: node.displayNone,
          children: [
            for (final c in node.children) _applySize(c, width, height),
          ],
        ),
      SvgUse() => node, // should not occur after flatten
      SvgShape() => node,
    };
  }
}
