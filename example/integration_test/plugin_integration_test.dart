// Integration test: runs the full pipeline (load SVG → convert to Lottie →
// hand to thorvg) via the public widget API.

import 'package:anim_svg/anim_svg.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AnimSvgView.asset renders without throwing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimSvgView.asset(
            'assets/svg_anim_1.svg',
            width: 200,
            height: 300,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.byType(AnimSvgView), findsOneWidget);
  });
}
