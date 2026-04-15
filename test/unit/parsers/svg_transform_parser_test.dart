import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('SvgTransformParser numeric tokenization', () {
    const p = SvgTransformParser();

    test('compact notation: minus acts as delimiter', () {
      final xs = p.parse('translate(1.01-2)');
      expect(xs, hasLength(1));
      expect(xs[0].kind, SvgTransformKind.translate);
      expect(xs[0].values, [1.01, -2]);
    });

    test('chained compact numbers: matrix(a-b-c-d-e-f)', () {
      final xs = p.parse('matrix(1-2-3-4-5-6)');
      // matrix(1,-2,-3,-4,-5,-6) decomposed into TRS.
      expect(xs.map((x) => x.kind), [
        SvgTransformKind.translate,
        SvgTransformKind.rotate,
        SvgTransformKind.scale,
      ]);
      // e, f (elements 4, 5 after sign split) are translate.
      expect(xs[0].values, [-5, -6]);
    });

    test('scientific notation survives compact grouping', () {
      final xs = p.parse('translate(1.01e-2-3)');
      expect(xs[0].values, [0.0101, -3]);
    });

    test('plain space-separated still works', () {
      final xs = p.parse('translate(10 20)scale(.5)');
      expect(xs, hasLength(2));
      expect(xs[0].values, [10, 20]);
      expect(xs[1].values, [0.5, 0.5]);
    });
  });
}
