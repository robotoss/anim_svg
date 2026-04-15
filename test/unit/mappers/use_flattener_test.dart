import 'dart:io';

import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  test('UseFlattener replaces <use> with referenced def', () {
    final svg = File('test/fixtures/minimal_use_defs.svg').readAsStringSync();
    final parsed = SvgParser().parse(svg);
    final flat = const UseFlattener().flatten(parsed);

    expect(flat.defs.byId, isEmpty);

    // Root → <g translate> → [<g with use-transforms>(Image), <g with translate>(Image)]
    final outerGroup = flat.root.children.single as SvgGroup;
    expect(outerGroup.children, hasLength(2));

    for (final child in outerGroup.children) {
      expect(child, isA<SvgGroup>());
      final wrapped = child as SvgGroup;
      expect(wrapped.children.single, isA<SvgImage>());
    }
  });

  test('throws on unknown href', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1 1">'
        '<use xlink:href="#missing"/></svg>';
    final parsed = SvgParser().parse(svg);
    expect(
      () => const UseFlattener().flatten(parsed),
      throwsA(isA<ParseException>()),
    );
  });
}
