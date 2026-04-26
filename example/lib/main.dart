import 'package:anim_svg/anim_svg.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const _assets = [
    'https://betinia.se/dimg/game/1709650499409_easternemeraldsanimatedsvg400x600.svg',
    'https://betinia.se/dimg/v2/game/aebb8d73-6ad3-4243-b387-ab66984fd22f-wol400x6003fix.svg',
    'https://betinia.se/dimg/v2/game/08c843fb-ace1-4959-9cfc-61145def219e-breakthepiggybank400x600.svg',
    'https://betinia.se/dimg/v2/game/75e2275a-b6ca-416d-9867-dd067f8e8b8d-777hotreelssupercharged400x600logoontop.svg',
    'https://betinia.se/dimg/game/1709650499409_easternemeraldsanimatedsvg400x600.svg',
    'https://betinia.se/dimg/v2/game/aebb8d73-6ad3-4243-b387-ab66984fd22f-wol400x6003fix.svg',
    'https://betinia.se/dimg/v2/game/08c843fb-ace1-4959-9cfc-61145def219e-breakthepiggybank400x600.svg',
    'https://betinia.se/dimg/v2/game/75e2275a-b6ca-416d-9867-dd067f8e8b8d-777hotreelssupercharged400x600logoontop.svg',
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('anim_svg demo')),
        body: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final cellW = constraints.maxWidth - gap * 2;
            final cellH = (constraints.maxHeight - gap * (_assets.length + 1)) / _assets.length;
            return ListView.separated(
              padding: const EdgeInsets.all(gap),
              itemCount: _assets.length,
              separatorBuilder: (_, __) => const SizedBox(height: gap),
              itemBuilder: (context, index) {
                final path = _assets[index];
                return SizedBox(
                  height: cellH,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AnimSvgView.network(
                        width: cellW,
                        height: cellH,
                        renderScale: 2.0,
                        path,
                        startDelay: Duration(milliseconds: 10 + index),
                        controller: AnimSvgController(),
                        errorBuilder: (ctx, err, _) => Padding(
                          padding: const EdgeInsets.all(12),
                          child: Center(
                            child: Text(
                              '${path.split('/').last}\n\n$err',
                              style: const TextStyle(fontSize: 10, color: Colors.red),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
