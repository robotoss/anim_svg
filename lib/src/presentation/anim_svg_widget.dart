import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:thorvg_plus/thorvg.dart' as tvg;
import 'package:visibility_detector/visibility_detector.dart';

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
    this.startDelay,
    this.renderScale = 1.0,
    this.disposeWhenInvisible = true,
    this.disposeDelay = const Duration(milliseconds: 700),
    this.showDelay = const Duration(milliseconds: 150),
    this.useGl = false,
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
    Duration? startDelay,
    double renderScale = 1.0,
    bool disposeWhenInvisible = true,
    Duration disposeDelay = const Duration(milliseconds: 700),
    Duration showDelay = const Duration(milliseconds: 150),
    bool useGl = false,
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
      startDelay: startDelay,
      renderScale: renderScale,
      disposeWhenInvisible: disposeWhenInvisible,
      disposeDelay: disposeDelay,
      showDelay: showDelay,
      useGl: useGl,
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
    Duration? startDelay,
    double renderScale = 1.0,
    bool disposeWhenInvisible = true,
    Duration disposeDelay = const Duration(milliseconds: 700),
    Duration showDelay = const Duration(milliseconds: 150),
    bool useGl = false,
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
      startDelay: startDelay,
      renderScale: renderScale,
      disposeWhenInvisible: disposeWhenInvisible,
      disposeDelay: disposeDelay,
      showDelay: showDelay,
      useGl: useGl,
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
    Duration? startDelay,
    double renderScale = 1.0,
    bool disposeWhenInvisible = true,
    Duration disposeDelay = const Duration(milliseconds: 700),
    Duration showDelay = const Duration(milliseconds: 150),
    bool useGl = false,
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
      startDelay: startDelay,
      renderScale: renderScale,
      disposeWhenInvisible: disposeWhenInvisible,
      disposeDelay: disposeDelay,
      showDelay: showDelay,
      useGl: useGl,
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

  /// Delays mounting of the thorvg engine. Used to stagger initial
  /// `tvg.load` calls across multiple animations in a list so that 8
  /// synchronous `SwCanvas` setups don't collide in a single frame.
  /// While the delay is pending the widget renders its loadingBuilder.
  final Duration? startDelay;

  /// Multiplier applied to logical [width] / [height] when sizing the
  /// native render buffer. `1.0` (default) renders at logical pixels —
  /// cheapest at the cost of softness on high-DPR displays. Bump to the
  /// device DPR (e.g. 2.0–3.0) for crisper output, at roughly
  /// `renderScale²` more rasterization cost.
  ///
  /// thorvg uses a CPU SwCanvas; for many simultaneous animations the
  /// shared render thread can't keep up at full DPR, which is why the
  /// default is `1.0`.
  final double renderScale;

  /// Tear down the native thorvg handle, GPU surface, and RGBA frame
  /// buffer when this widget is fully off-screen for [disposeDelay], and
  /// re-create them after [showDelay] of returning to visibility.
  ///
  /// Defaults to `true`. On Android API 28+ the underlying texture is
  /// driven by `TextureRegistry.createSurfaceProducer` (since
  /// `thorvg_plus 1.1.0`), which uses `ImageReader`/`HardwareBuffer`
  /// internally — fast create/destroy under heavy scrolling is safe.
  /// Below API 28 the engine falls back to `SurfaceTexture`; on those
  /// devices very long, very fast scrolling sessions could in principle
  /// hit the legacy BufferQueue fence-FD pressure documented in
  /// flutter/flutter#94916. Set this to `false` on those targets if you
  /// observe FD growth in `/proc/<pid>/fd` during long scrolls.
  ///
  /// **Limitation**: visibility is detected geometrically against the
  /// viewport. Items obscured by a `Stack` overlay in the same layer
  /// tree are *not* considered invisible. Use `Offstage` /
  /// `Visibility(visible: false)` at the call site if you need to drop
  /// memory in those cases.
  final bool disposeWhenInvisible;

  /// Wait this long after the widget becomes fully invisible before
  /// disposing the native handle. Acts as a debounce against fast scrolls.
  final Duration disposeDelay;

  /// Wait this long after returning to visibility before re-creating the
  /// native handle. Symmetric debounce that suppresses native creates for
  /// items the user only fleetingly scrolls past.
  final Duration showDelay;

  /// Sprint 6 GL toggle (experimental). When `true` the native bridge
  /// constructs the C++ thorvg side around `tvg::GlCanvas` and routes
  /// rendering through ANGLE-Metal (iOS) / native EGL (Android).
  /// Default `false` keeps the SmartRender SwCanvas path that handles
  /// static backgrounds and list scenarios best. Flip to `true` for
  /// compositions where the SW path is genuinely CPU-bound.
  final bool useGl;

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
  // handle whose `.play()` we call reflectively. Nulled when we tear the
  // inner Lottie down for off-screen disposal so external callers don't
  // forward play()/pause() to a stale, already-disposed controller.
  dynamic _engine;
  StackTrace? _lastStack;
  bool _mountReady = true;

  // Visibility-driven render gating.
  //
  // The Phase 2 render path holds a non-trivial native footprint per
  // mounted instance (thorvg scene + RGBA buffer + platform texture); off-
  // screen items keep paying that cost until ListView.builder evicts them
  // past `cacheExtent`. We supplement that natural lifecycle by tearing
  // down the inner `tvg.Lottie.memory` subtree as soon as the widget has
  // been fully invisible for `widget.disposeDelay`, and re-mounting it
  // after `widget.showDelay` of returning to visibility.
  bool _renderEnabled = true;
  bool _tickerEnabled = true;
  Timer? _hideTimer;
  Timer? _showTimer;

  AnimSvgLogger get _log => widget.logger ?? DeveloperLogger();

  @override
  void initState() {
    super.initState();
    _lottieBytesFuture = _loadAndConvert();
    final delay = widget.startDelay;
    if (delay != null && delay > Duration.zero) {
      _mountReady = false;
      Future.delayed(delay, () {
        if (!mounted) return;
        setState(() => _mountReady = true);
      });
    }
    widget.controller?.attachInternal(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TabBarView and friends disable TickerMode on inactive tabs without
    // changing geometric visibility, so VisibilityDetector wouldn't catch
    // it. Treat ticker-disabled the same as fully off-screen.
    final enabled = TickerMode.of(context);
    if (enabled == _tickerEnabled) return;
    _tickerEnabled = enabled;
    _log.debug('widget.visibility',
        enabled ? 'ticker enabled' : 'ticker disabled (e.g. inactive TabBarView)',
        fields: {'source': widget.sourceLabel});
    if (!enabled) {
      _scheduleHide(immediate: true);
    } else {
      _scheduleShow();
    }
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
    _hideTimer?.cancel();
    _showTimer?.cancel();
    widget.controller?.detachInternal(this);
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!widget.disposeWhenInvisible) return;
    final visible = info.visibleFraction > 0 && _tickerEnabled;
    _log.debug('widget.visibility', visible ? 'visible' : 'invisible',
        fields: {
          'source': widget.sourceLabel,
          'fraction': info.visibleFraction,
          'render_enabled': _renderEnabled,
        });
    if (visible) {
      _scheduleShow();
    } else {
      _scheduleHide();
    }
  }

  void _scheduleHide({bool immediate = false}) {
    _showTimer?.cancel();
    _showTimer = null;
    if (!_renderEnabled && _hideTimer == null) return; // already hidden
    _hideTimer?.cancel();
    final delay = immediate ? Duration.zero : widget.disposeDelay;
    _log.debug('widget.visibility', 'hide scheduled', fields: {
      'source': widget.sourceLabel,
      'delay_ms': delay.inMilliseconds,
    });
    _hideTimer = Timer(delay, () {
      _hideTimer = null;
      if (!mounted) return;
      if (_renderEnabled) {
        _log.info('widget.visibility', 'hide fired → dispose native handle',
            fields: {'source': widget.sourceLabel});
        setState(() {
          _renderEnabled = false;
          // The inner Lottie unmount will dispose the controller; clear
          // our reference so external play()/pause() calls don't target it.
          _engine = null;
        });
      }
    });
  }

  void _scheduleShow() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_renderEnabled && _showTimer == null) return; // already shown
    _showTimer?.cancel();
    _log.debug('widget.visibility', 'show scheduled', fields: {
      'source': widget.sourceLabel,
      'delay_ms': widget.showDelay.inMilliseconds,
    });
    _showTimer = Timer(widget.showDelay, () {
      _showTimer = null;
      if (!mounted) return;
      if (!_renderEnabled) {
        _log.info('widget.visibility', 'show fired → re-mount native handle',
            fields: {'source': widget.sourceLabel});
        setState(() => _renderEnabled = true);
      }
    });
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
    final inner = FutureBuilder<_PipelineOutput>(
      future: _lottieBytesFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          final eb = widget.errorBuilder;
          if (eb != null) return eb(context, snap.error!, _lastStack);
          return _defaultError();
        }
        if (!snap.hasData || !_mountReady) {
          final lb = widget.loadingBuilder;
          return lb != null ? lb(context) : _defaultLoading();
        }
        final out = snap.data!;
        if (out.layerCount == 0) {
          final pb = widget.placeholderBuilder;
          return pb != null ? pb(context) : _defaultPlaceholder();
        }
        return RepaintBoundary(
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: _renderEnabled
                ? FittedBox(
                    fit: widget.fit,
                    alignment: widget.alignment,
                    child: tvg.Lottie.memory(
                      out.bytes,
                      width: widget.width,
                      height: widget.height,
                      animate: widget.animate,
                      repeat: widget.repeat,
                      reverse: false,
                      renderScale: widget.renderScale,
                      useGl: widget.useGl,
                      onLoaded: (engine) {
                        _engine = engine;
                        _log.info('widget.engine', 'thorvg loaded',
                            fields: {'source': widget.sourceLabel});
                      },
                    ),
                  )
                // Off-screen placeholder. Same outer SizedBox keeps layout
                // stable; the inner SizedBox.shrink() avoids painting
                // anything while the native handle is torn down. We pay
                // ~one MethodChannel `create` round-trip on re-show.
                : const SizedBox.shrink(),
          ),
        );
      },
    );
    if (!widget.disposeWhenInvisible) return inner;
    return VisibilityDetector(
      // ObjectKey(this) is stable for the life of this State (one mount)
      // and identity-compared, so two AnimSvgViews with the same source
      // get distinct visibility entries inside VisibilityDetector's
      // internal registry.
      key: ObjectKey(this),
      onVisibilityChanged: _onVisibilityChanged,
      child: inner,
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
