import 'package:anim_svg/anim_svg.dart';
import 'package:test/test.dart';

void main() {
  group('SvgPathDataParser', () {
    test('M L Z → one closed contour with 3 vertices', () {
      final contours =
          const SvgPathDataParser().parse('M 0 0 L 10 0 L 10 10 Z');
      expect(contours, hasLength(1));
      final c = contours.single;
      expect(c.closed, isTrue);
      expect(c.vertices, [
        [0, 0],
        [10, 0],
        [10, 10],
      ]);
      // All tangents zero (straight segments).
      expect(c.inTangents.every((t) => t[0] == 0 && t[1] == 0), isTrue);
      expect(c.outTangents.every((t) => t[0] == 0 && t[1] == 0), isTrue);
    });

    test('M C Z preserves control points as tangent deltas', () {
      final contours = const SvgPathDataParser()
          .parse('M 0 0 C 10 0 20 10 30 10 Z');
      final c = contours.single;
      expect(c.vertices, [
        [0, 0],
        [30, 10],
      ]);
      // Out-tangent of vertex 0 points toward control 1 (10,0).
      expect(c.outTangents[0], [10, 0]);
      // In-tangent of vertex 1 is (20-30, 10-10) = (-10, 0).
      expect(c.inTangents[1], [-10, 0]);
    });

    test('two sub-paths produce two contours', () {
      final contours = const SvgPathDataParser()
          .parse('M 0 0 L 1 1 Z M 5 5 L 6 6 Z');
      expect(contours, hasLength(2));
      expect(contours[0].vertices.first, [0, 0]);
      expect(contours[1].vertices.first, [5, 5]);
    });

    test('relative m l acts relative to pen position', () {
      final contours =
          const SvgPathDataParser().parse('M 10 10 l 5 0 l 0 5 z');
      final c = contours.single;
      expect(c.vertices, [
        [10, 10],
        [15, 10],
        [15, 15],
      ]);
    });
  });

  group('helpers', () {
    test('ellipseContour has 4 cubic vertices', () {
      final c = ellipseContour(0, 0, 10, 10);
      expect(c.vertices, hasLength(4));
      expect(c.closed, isTrue);
    });

    test('rectContour without radii is a 4-vertex rectangle', () {
      final c = rectContour(0, 0, 100, 50, 0, 0);
      expect(c.vertices, [
        [0, 0],
        [100, 0],
        [100, 50],
        [0, 50],
      ]);
      expect(c.closed, isTrue);
    });
  });
}
