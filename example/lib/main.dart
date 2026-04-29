import 'package:anim_svg/anim_svg.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'perf_overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  /// 6 distinct SVGs, repeated [_repeatCount] times to make the list long
  /// enough that some items are visible and the rest sit below the fold.
  /// Scrolling them past the viewport (and pausing at the bottom) is the
  /// only way to exercise the visibility-driven dispose path.
  static const _baseAssets = [
    'assets/svg_anim_1.svg',
    'assets/svg_anim_2.svg',
    'assets/svg_anim_3.svg',
    'assets/svg_anim_4.svg',
    'assets/svg_anim_5.svg',
    'assets/svg_anim_6.svg',
  ];

  static const int _repeatCount = 4; // → 24 items total
  static const double _cellHeight = 220.0;
  static const double _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final itemCount = _baseAssets.length * _repeatCount;
    return MaterialApp(
      home: PerfOverlay(
        child: Scaffold(
        appBar: AppBar(title: const Text('anim_svg demo')),
        body: ListView.separated(
          padding: const EdgeInsets.all(_gap),
          itemCount: itemCount,
          separatorBuilder: (_, _) => const SizedBox(height: _gap),
          itemBuilder: (context, index) {
            final path = _baseAssets[index % _baseAssets.length];
            return _DemoTile(
              index: index,
              assetPath: path,
              height: _cellHeight,
            );
          },
        ),
        ),
      ),
    );
  }
}

/// One row in the demo list. The `Stack` overlay shows the item index and
/// asset filename so a reader can correlate live logs with the visible
/// position. The `AnimSvgView` itself is wrapped in `_AspectFittedSvg` so
/// thorvg's render buffer hugs the source aspect rather than the cell box.
class _DemoTile extends StatelessWidget {
  const _DemoTile({
    required this.index,
    required this.assetPath,
    required this.height,
  });

  final int index;
  final String assetPath;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cellW = MediaQuery.sizeOf(context).width - MyApp._gap * 2;
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              _AspectFittedSvg(
                assetPath: assetPath,
                maxWidth: cellW,
                maxHeight: height,
                index: index,
              ),
              Positioned(
                top: 6,
                left: 6,
                child: _IndexBadge(index: index, asset: assetPath),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Top-left badge showing the item's position in the list and the asset
/// filename. Pure visual aid for debug — no functional role.
class _IndexBadge extends StatelessWidget {
  const _IndexBadge({required this.index, required this.asset});

  final int index;
  final String asset;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '#$index · ${asset.split('/').last}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Loads the SVG asset once, reads the intrinsic `viewBox`/`width`/`height`,
/// then renders `AnimSvgView` sized so it fits inside `maxWidth x maxHeight`
/// while preserving the source aspect ratio.
class _AspectFittedSvg extends StatefulWidget {
  const _AspectFittedSvg({
    required this.assetPath,
    required this.maxWidth,
    required this.maxHeight,
    required this.index,
  });

  final String assetPath;
  final double maxWidth;
  final double maxHeight;
  final int index;

  @override
  State<_AspectFittedSvg> createState() => _AspectFittedSvgState();
}

class _AspectFittedSvgState extends State<_AspectFittedSvg> {
  late final Future<_Size> _sizeFuture = _resolveSize();

  Future<_Size> _resolveSize() async {
    final text = await rootBundle.loadString(widget.assetPath);
    return _parseSize(text) ?? const _Size(1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Size>(
      future: _sizeFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return SizedBox(width: widget.maxWidth, height: widget.maxHeight);
        }
        final size = snap.data!;
        final scale = (widget.maxWidth / size.w).clamp(0.0, widget.maxHeight / size.h);
        final renderW = size.w * scale;
        final renderH = size.h * scale;
        return Center(
          child: SizedBox(
            width: renderW,
            height: renderH,
            child: AnimSvgView.asset(
              widget.assetPath,
              width: renderW,
              height: renderH,
              renderScale: 2.0,
              // Default DeveloperLogger() emits to dart:developer. The
              // explicit pass keeps this demo self-documenting: every
              // pipeline stage (load / convert / engine / visibility /
              // hide / show) is tagged with `[anim_svg] [...]` in the
              // run console so the reader can see exactly which steps
              // are firing for which list item.
              logger: DeveloperLogger(),
              controller: AnimSvgController(),
              errorBuilder: (ctx, err, _) => Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: Text(
                    '#${widget.index} ${widget.assetPath.split('/').last}\n\n$err',
                    style: const TextStyle(fontSize: 10, color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Size {
  const _Size(this.w, this.h);
  final double w;
  final double h;
}

/// Extracts SVG intrinsic dimensions: prefers `viewBox` (last two numbers),
/// falls back to `width`/`height`. Returns null if neither is usable.
_Size? _parseSize(String svg) {
  final viewBox = RegExp(r'viewBox\s*=\s*"([^"]+)"').firstMatch(svg);
  if (viewBox != null) {
    final parts = viewBox.group(1)!.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();
    if (parts.length == 4) {
      final w = double.tryParse(parts[2]);
      final h = double.tryParse(parts[3]);
      if (w != null && h != null && w > 0 && h > 0) return _Size(w, h);
    }
  }
  final wAttr = RegExp(r'<svg\b[^>]*\swidth\s*=\s*"([^"]+)"').firstMatch(svg);
  final hAttr = RegExp(r'<svg\b[^>]*\sheight\s*=\s*"([^"]+)"').firstMatch(svg);
  if (wAttr != null && hAttr != null) {
    final w = double.tryParse(wAttr.group(1)!.replaceAll(RegExp(r'[^\d.]'), ''));
    final h = double.tryParse(hAttr.group(1)!.replaceAll(RegExp(r'[^\d.]'), ''));
    if (w != null && h != null && w > 0 && h > 0) return _Size(w, h);
  }
  return null;
}
