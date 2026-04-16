import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:thorvg/thorvg.dart' as tvg;

import '../core/logger.dart';
import '../data/network/network_svg_loader.dart';
import '../domain/usecases/convert_svg_to_lottie.dart';
import 'anim_svg_controller.dart';

/// Renders an animated SVG by converting it to Lottie JSON in-process and
/// handing the JSON to thorvg.
///
/// Three sources are supported via factory constructors:
///   * [AnimSvgView.asset]   — bundled asset path
///   * [AnimSvgView.string]  — raw SVG string already in memory
///   * [AnimSvgView.network] — HTTP URL, with disk cache for the converted
///                             Lottie JSON (TTL 7 days, keyed by URL)
///
/// Layout: every constructor accepts [fit] and [alignment] with the same
/// semantics as `Image` (default `BoxFit.contain` / `Alignment.center`).
/// thorvg itself rasterises at 1:1 — fit/alignment are applied via a
/// [FittedBox] wrapper.
///
/// Debugging: pass a [logger] (e.g. `DeveloperLogger()` or `PrintLogger()`)
/// to trace every stage. Use [onLottieReady] to capture the generated JSON
/// (feed it to https://lottiefiles.com/preview to isolate render issues).
class AnimSvgView extends StatefulWidget {
  const AnimSvgView._({
    super.key,
    this.svgLoader,
    this.lottieBytesLoader,
    required this.sourceLabel,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.repeat = true,
    this.animate = true,
    this.controller,
    this.errorBuilder,
    this.loadingBuilder,
    this.placeholderBuilder,
    this.logger,
    this.onLottieReady,
  }) : assert(svgLoader != null || lottieBytesLoader != null,
            'Exactly one of svgLoader or lottieBytesLoader must be provided');

  factory AnimSvgView.asset(
    String assetPath, {
    Key? key,
    required double width,
    required double height,
    BoxFit fit = BoxFit.contain,
    AlignmentGeometry alignment = Alignment.center,
    bool repeat = true,
    bool animate = true,
    AnimSvgController? controller,
    Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
    WidgetBuilder? loadingBuilder,
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
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      animate: animate,
      controller: controller,
      errorBuilder: errorBuilder,
      loadingBuilder: loadingBuilder,
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
    BoxFit fit = BoxFit.contain,
    AlignmentGeometry alignment = Alignment.center,
    bool repeat = true,
    bool animate = true,
    AnimSvgController? controller,
    Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
    WidgetBuilder? loadingBuilder,
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
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      animate: animate,
      controller: controller,
      errorBuilder: errorBuilder,
      loadingBuilder: loadingBuilder,
      placeholderBuilder: placeholderBuilder,
      logger: logger,
      onLottieReady: onLottieReady,
    );
  }

  /// Loads an animated SVG from [url], converts it to Lottie JSON and
  /// caches the converted bytes on disk for 7 days.
  ///
  /// On a cache hit the network and the Rust converter are both skipped.
  /// Pass a custom [cacheManager] to override the default policy (TTL,
  /// max objects, location).
  factory AnimSvgView.network(
    String url, {
    Key? key,
    required double width,
    required double height,
    BoxFit fit = BoxFit.contain,
    AlignmentGeometry alignment = Alignment.center,
    bool repeat = true,
    bool animate = true,
    AnimSvgController? controller,
    Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
    WidgetBuilder? loadingBuilder,
    Widget Function(BuildContext)? placeholderBuilder,
    AnimSvgLogger? logger,
    void Function(Uint8List lottieBytes)? onLottieReady,
    BaseCacheManager? cacheManager,
    NetworkSvgLoader? loader,
  }) {
    final effectiveLoader = loader ??
        NetworkSvgLoader(
          cacheManager: cacheManager,
          logger: logger ?? DeveloperLogger(),
        );
    return AnimSvgView._(
      key: key,
      lottieBytesLoader: () => effectiveLoader.loadLottieBytes(url),
      sourceLabel: 'network:$url',
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      animate: animate,
      controller: controller,
      errorBuilder: errorBuilder,
      loadingBuilder: loadingBuilder,
      placeholderBuilder: placeholderBuilder,
      logger: logger,
      onLottieReady: onLottieReady,
    );
  }

  final Future<String> Function()? svgLoader;
  final Future<Uint8List> Function()? lottieBytesLoader;
  final String sourceLabel;
  final double width;
  final double height;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final bool repeat;
  final bool animate;
  final AnimSvgController? controller;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  /// Built while the source is loading / converting (network only path
  /// reaches this state in practice; assets resolve synchronously enough
  /// that the placeholder rarely renders). Defaults to a centered
  /// [CircularProgressIndicator].
  final WidgetBuilder? loadingBuilder;

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
      if (widget.lottieBytesLoader != null) {
        final sw = Stopwatch()..start();
        final bytes = await widget.lottieBytesLoader!();
        sw.stop();
        final layerCount = _layerCountFromLottieBytes(bytes);
        log.info('widget', 'lottie ready (preconverted)', fields: {
          'json_bytes': bytes.length,
          'layers': layerCount,
          'duration_ms': sw.elapsedMilliseconds,
        });
        if (layerCount == 0) return _PipelineOutput(Uint8List(0), 0);
        widget.onLottieReady?.call(bytes);
        return _PipelineOutput(bytes, layerCount);
      }

      final loadSw = Stopwatch()..start();
      final svg = await widget.svgLoader!();
      loadSw.stop();
      log.debug('widget.load', 'svg loaded', fields: {
        'bytes': svg.length,
        'duration_ms': loadSw.elapsedMilliseconds,
        'head': _head(svg),
      });

      final converter = ConvertSvgToLottie(logger: log);
      final envelope = converter.convertToEnvelope(svg);
      final lottieMap = envelope.lottie;
      final layers =
          lottieMap is Map<String, Object?> ? lottieMap['layers'] : null;
      final layerCount = layers is List ? layers.length : 0;
      if (layerCount == 0) {
        log.warn('widget', 'conversion produced zero layers → placeholder',
            fields: {'source': widget.sourceLabel});
        return _PipelineOutput(Uint8List(0), 0);
      }
      final jsonStr = envelope.lottieJson;
      // package:thorvg 1.0 decodes the buffer twice: `String.fromCharCodes`
      // to feed `jsonDecode` (for layer size) and then again for native
      // FFI. Any trailing byte past the closing `}` — e.g. a NUL padding —
      // makes `jsonDecode` throw `FormatException: Unexpected character`.
      // We keep the buffer exactly utf8-encoded. The SIGSEGV documented in
      // ADR-011 was triggered only when `op==0`; the op>=1 clamp in
      // SvgToLottieMapper is sufficient on its own.
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      log.info('widget', 'lottie ready',
          fields: {'json_bytes': bytes.length, 'layers': layerCount});

      widget.onLottieReady?.call(bytes);
      return _PipelineOutput(bytes, layerCount);
    } catch (e, s) {
      _lastStack = s;
      log.error('widget', 'pipeline failed',
          error: e, stack: s, fields: {'source': widget.sourceLabel});
      rethrow;
    }
  }

  int _layerCountFromLottieBytes(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) {
        final layers = decoded['layers'];
        if (layers is List) return layers.length;
      }
    } catch (_) {
      // Cached bytes that don't parse as Lottie JSON are treated as
      // having renderable content; thorvg will surface the real error.
    }
    return 1;
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
          return _defaultError();
        }
        if (!snap.hasData) {
          final lb = widget.loadingBuilder;
          return lb != null ? lb(context) : _defaultLoading();
        }
        final out = snap.data!;
        if (out.layerCount == 0) {
          final pb = widget.placeholderBuilder;
          return pb != null ? pb(context) : _defaultPlaceholder();
        }
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: FittedBox(
            fit: widget.fit,
            alignment: widget.alignment,
            child: tvg.Lottie.memory(
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
            ),
          ),
        );
      },
    );
  }

  Widget _defaultLoading() {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
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

  Widget _defaultError() {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: const Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: Colors.black26,
        ),
      ),
    );
  }
}
