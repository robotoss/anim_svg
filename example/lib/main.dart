import 'package:anim_svg/anim_svg.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const _assets = [
    'assets/svg_anim_1.svg',
    'assets/svg_anim_2.svg',
    'assets/svg_anim_3.svg',
    'assets/svg_anim_4.svg',
    'assets/svg_anim_5.svg',
    'assets/svg_anim_6.svg',
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
                      child: _AspectFittedSvg(assetPath: path, maxWidth: cellW, maxHeight: cellH),
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

/// Loads the SVG asset once, reads the intrinsic `viewBox`/`width`/`height`,
/// then renders `AnimSvgView` sized so it fits inside `maxWidth x maxHeight`
/// while preserving the source aspect ratio.
class _AspectFittedSvg extends StatefulWidget {
  const _AspectFittedSvg({
    required this.assetPath,
    required this.maxWidth,
    required this.maxHeight,
  });

  final String assetPath;
  final double maxWidth;
  final double maxHeight;

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
              controller: AnimSvgController(),
              errorBuilder: (ctx, err, _) => Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: Text(
                    '${widget.assetPath.split('/').last}\n\n$err',
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
