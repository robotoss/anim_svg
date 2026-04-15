import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:thorvg/thorvg.dart' as tvg;

import '../core/errors.dart';
import '../core/logger.dart';
import '../domain/usecases/convert_svg_to_lottie.dart';
import 'anim_svg_controller.dart';

/// Renders an animated SVG by converting it to Lottie JSON in-process and
/// handing the JSON to thorvg.
///
/// Debugging: pass a [logger] (e.g. `DeveloperLogger()` or `PrintLogger()`)
/// to trace every stage. Use [onLottieReady] to capture the generated JSON
/// (feed it to https://lottiefiles.com/preview to isolate render issues).
class AnimSvgView extends StatefulWidget {
  const AnimSvgView._({
    super.key,
    required this.svgLoader,
    required this.sourceLabel,
    required this.width,
    required this.height,
    this.repeat = true,
    this.animate = true,
    this.controller,
    this.errorBuilder,
    this.placeholderBuilder,
    this.logger,
    this.onLottieReady,
  });

  factory AnimSvgView.asset(
    String assetPath, {
    Key? key,
    required double width,
    required double height,
    bool repeat = true,
    bool animate = true,
    AnimSvgController? controller,
    Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
    Widget Function(BuildContext)? placeholderBuilder,
    AnimSvgLogger? logger,
    void Function(Uint8List lottieBytes)? onLottieReady,
  }) {
    return AnimSvgView._(
      key: key,
      svgLoader: () => rootBundle.loadString(assetPath),
      sourceLabel: 'asset:$assetPath',
      width: width,
      height: height,
      repeat: repeat,
      animate: animate,
      controller: controller,
      errorBuilder: errorBuilder,
      placeholderBuilder: placeholderBuilder,
      logger: logger,
      onLottieReady: onLottieReady,
    );
  }

  factory AnimSvgView.string(
    String svgXml, {
    Key? key,
    required double width,
    required double height,
    bool repeat = true,
    bool animate = true,
    AnimSvgController? controller,
    Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
    Widget Function(BuildContext)? placeholderBuilder,
    AnimSvgLogger? logger,
    void Function(Uint8List lottieBytes)? onLottieReady,
  }) {
    return AnimSvgView._(
      key: key,
      svgLoader: () => Future.value(svgXml),
      sourceLabel: 'string(${svgXml.length} bytes)',
      width: width,
      height: height,
      repeat: repeat,
      animate: animate,
      controller: controller,
      errorBuilder: errorBuilder,
      placeholderBuilder: placeholderBuilder,
      logger: logger,
      onLottieReady: onLottieReady,
    );
  }

  final Future<String> Function() svgLoader;
  final String sourceLabel;
  final double width;
  final double height;
  final bool repeat;
  final bool animate;
  final AnimSvgController? controller;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  /// Called when conversion succeeds but produces zero renderable layers
  /// (e.g. an SVG that is entirely vector shapes/filters we don't yet
  /// support). Defaults to a neutral grey box with "empty" label.
  final Widget Function(BuildContext)? placeholderBuilder;
  final AnimSvgLogger? logger;
  final void Function(Uint8List lottieBytes)? onLottieReady;

  @override
  State<AnimSvgView> createState() => _AnimSvgViewState();
}

class _PipelineOutput {
  const _PipelineOutput(this.bytes, this.layerCount);
  final Uint8List bytes;
  final int layerCount;
}

class _AnimSvgViewState extends State<AnimSvgView> implements AnimSvgBinding {
  late Future<_PipelineOutput> _lottieBytesFuture;
  // `Thorvg` engine type is not exported by thorvg 1.0; onLoaded gives us a
  // handle whose `.play()` we call reflectively.
  dynamic _engine;
  StackTrace? _lastStack;

  AnimSvgLogger get _log => widget.logger ?? DeveloperLogger();

  @override
  void initState() {
    super.initState();
    _lottieBytesFuture = _loadAndConvert();
    widget.controller?.attachInternal(this);
  }

  @override
  void didUpdateWidget(covariant AnimSvgView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.detachInternal(this);
      widget.controller?.attachInternal(this);
    }
  }

  @override
  void dispose() {
    widget.controller?.detachInternal(this);
    super.dispose();
  }

  Future<_PipelineOutput> _loadAndConvert() async {
    final log = _log;
    log.info('widget', 'load start',
        fields: {'source': widget.sourceLabel, 'w': widget.width, 'h': widget.height});
    try {
      final loadSw = Stopwatch()..start();
      final svg = await widget.svgLoader();
      loadSw.stop();
      log.debug('widget.load', 'svg loaded', fields: {
        'bytes': svg.length,
        'duration_ms': loadSw.elapsedMilliseconds,
        'head': _head(svg),
      });

      final converter = ConvertSvgToLottie(logger: log);
      final lottie = converter.convert(svg);
      if (lottie.layers.isEmpty) {
        log.warn('widget', 'conversion produced zero layers → placeholder',
            fields: {'source': widget.sourceLabel});
        return _PipelineOutput(Uint8List(0), 0);
      }
      final jsonStr = converter.convertToJson(svg);
      // package:thorvg 1.0 decodes the buffer twice: `String.fromCharCodes`
      // to feed `jsonDecode` (for layer size) and then again for native
      // FFI. Any trailing byte past the closing `}` — e.g. a NUL padding —
      // makes `jsonDecode` throw `FormatException: Unexpected character`.
      // We keep the buffer exactly utf8-encoded. The SIGSEGV documented in
      // ADR-011 was triggered only when `op==0`; the op>=1 clamp in
      // SvgToLottieMapper is sufficient on its own.
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      log.info('widget', 'lottie ready',
          fields: {'json_bytes': bytes.length, 'layers': lottie.layers.length});

      widget.onLottieReady?.call(bytes);
      return _PipelineOutput(bytes, lottie.layers.length);
    } catch (e, s) {
      _lastStack = s;
      log.error('widget', 'pipeline failed',
          error: e, stack: s, fields: {'source': widget.sourceLabel});
      rethrow;
    }
  }

  String _head(String s) {
    final h = s.length > 120 ? '${s.substring(0, 120)}…' : s;
    return h.replaceAll('\n', ' ').replaceAll('  ', ' ');
  }

  @override
  void play() {
    final e = _engine;
    if (e == null) {
      _log.warn('widget.play', 'engine is null (not loaded yet)');
      return;
    }
    _log.debug('widget.play', 'calling engine.play()');
    e.play();
  }

  @override
  void pause() {
    _log.warn('widget.pause',
        'thorvg 1.0 has no pause API; use animate:false on the widget');
  }

  @override
  void seek(double progress) {
    _log.warn('widget.seek',
        'thorvg 1.0 has no seek API; hook kept for forward compat',
        fields: {'progress': progress});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PipelineOutput>(
      future: _lottieBytesFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          final eb = widget.errorBuilder;
          if (eb != null) return eb(context, snap.error!, _lastStack);
          return _defaultError(snap.error!, _lastStack);
        }
        if (!snap.hasData) {
          return SizedBox(width: widget.width, height: widget.height);
        }
        final out = snap.data!;
        if (out.layerCount == 0) {
          final pb = widget.placeholderBuilder;
          return pb != null ? pb(context) : _defaultPlaceholder();
        }
        return tvg.Lottie.memory(
          out.bytes,
          width: widget.width,
          height: widget.height,
          animate: widget.animate,
          repeat: widget.repeat,
          reverse: false,
          onLoaded: (engine) {
            _engine = engine;
            _log.info('widget.engine', 'thorvg loaded');
          },
        );
      },
    );
  }

  Widget _defaultPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: const Color(0x11000000),
      alignment: Alignment.center,
      child: const Text(
        'no renderable content',
        style: TextStyle(color: Colors.black45, fontSize: 10),
      ),
    );
  }

  Widget _defaultError(Object error, StackTrace? stack) {
    final isKnown = error is UnsupportedFeatureException ||
        error is ParseException ||
        error is ConversionException;
    final msg = isKnown ? error.toString() : 'anim_svg error: $error';
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            child: Text(
              stack == null ? msg : '$msg\n\n$stack',
              style: const TextStyle(color: Colors.red, fontSize: 10),
              textAlign: TextAlign.left,
            ),
          ),
        ),
      ),
    );
  }
}
