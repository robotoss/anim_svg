/*
 * Copyright (c) 2024 - 2026 ThorVG project. All rights reserved.
 *
 * Licensed under the MIT License (see project LICENSE for details).
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'thorvg_controller.dart';
import 'utils.dart';

/// A Lottie/JSON animation rendered by the native thorvg engine into a
/// Flutter `Texture(textureId)`.
///
/// Rasterization runs on a per-instance native thread (`HandlerThread` on
/// Android, `DispatchQueue` on iOS) so the Flutter UI isolate is never
/// blocked by `SwCanvas::draw`. The widget's `build` cost is the cost of a
/// `Texture` widget — effectively a sampler — independent of how many
/// animations are on screen.
class Lottie extends StatefulWidget {
  const Lottie({
    super.key,
    required this.data,
    required this.width,
    required this.height,
    required this.animate,
    required this.repeat,
    required this.reverse,
    this.renderScale = 1.0,
    this.onLoaded,
  });

  final Future<String> data;
  final double width;
  final double height;
  final bool animate;
  final bool repeat;
  final bool reverse;

  /// Multiplier applied to the logical widget size when sizing the native
  /// rasterization buffer. The thorvg SwCanvas runs on the CPU, so cost
  /// scales with rendered pixel count.
  ///
  /// - `1.0` (default) — render at logical pixels. Cheapest; output will
  ///   look slightly soft on high-DPR (retina) screens because Flutter
  ///   then upscales the texture to the physical buffer.
  /// - device DPR (e.g. 2.5–3.0) — crispest, but rasterization cost is
  ///   ~`renderScale²` higher. With many simultaneous animations this can
  ///   exceed the shared render thread's frame budget.
  ///
  /// The default was lowered from `1 + (dpr - 1) * 0.75` after profiling
  /// 8 portrait slot animations on a high-DPR emulator: at the previous
  /// formula the render thread could not produce frames fast enough,
  /// causing visible stutter even though the UI thread was idle.
  final double renderScale;

  /// Invoked once the native handle and texture are ready. Use the supplied
  /// [ThorvgController] to drive `play`/`pause`/`seek`/`resize`. The
  /// controller is owned by the widget and disposed automatically.
  final void Function(ThorvgController controller)? onLoaded;

  static Lottie asset(
    String name, {
    Key? key,
    double? width,
    double? height,
    bool? animate,
    bool? repeat,
    bool? reverse,
    double? renderScale,
    AssetBundle? bundle,
    String? package,
    void Function(ThorvgController)? onLoaded,
  }) {
    return Lottie(
      key: key,
      data: parseAsset(name, bundle, package),
      width: width ?? 0,
      height: height ?? 0,
      animate: animate ?? true,
      repeat: repeat ?? true,
      reverse: reverse ?? false,
      renderScale: renderScale ?? 1.0,
      onLoaded: onLoaded,
    );
  }

  static Lottie file(
    io.File file, {
    Key? key,
    double? width,
    double? height,
    bool? animate,
    bool? repeat,
    bool? reverse,
    double? renderScale,
    void Function(ThorvgController)? onLoaded,
  }) {
    return Lottie(
      key: key,
      data: parseFile(file),
      width: width ?? 0,
      height: height ?? 0,
      animate: animate ?? true,
      repeat: repeat ?? true,
      reverse: reverse ?? false,
      renderScale: renderScale ?? 1.0,
      onLoaded: onLoaded,
    );
  }

  static Lottie memory(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    bool? animate,
    bool? repeat,
    bool? reverse,
    double? renderScale,
    void Function(ThorvgController)? onLoaded,
  }) {
    return Lottie(
      key: key,
      data: parseMemory(bytes),
      width: width ?? 0,
      height: height ?? 0,
      animate: animate ?? true,
      repeat: repeat ?? true,
      reverse: reverse ?? false,
      renderScale: renderScale ?? 1.0,
      onLoaded: onLoaded,
    );
  }

  static Lottie network(
    String src, {
    Key? key,
    double? width,
    double? height,
    bool? animate,
    bool? repeat,
    bool? reverse,
    double? renderScale,
    void Function(ThorvgController)? onLoaded,
  }) {
    return Lottie(
      key: key,
      data: parseSrc(src),
      width: width ?? 0,
      height: height ?? 0,
      animate: animate ?? true,
      repeat: repeat ?? true,
      reverse: reverse ?? false,
      renderScale: renderScale ?? 1.0,
      onLoaded: onLoaded,
    );
  }

  @override
  State<Lottie> createState() => _LottieState();
}

class _LottieState extends State<Lottie> {
  ThorvgController? _controller;
  Object? _error;

  // Tracks the dpr applied at controller creation. If the widget rebuilds
  // under a different dpr (e.g. window moves to another screen), we resize
  // the native buffer.
  double _appliedDpr = 1.0;
  double _appliedWidth = 0;
  double _appliedHeight = 0;

  // Guard against multiple in-flight loads racing on hot reload / size changes.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    // The first load needs MediaQuery; defer to first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadInitial();
    });
  }

  @override
  void didUpdateWidget(covariant Lottie oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.width != oldWidget.width || widget.height != oldWidget.height) {
      _maybeResize();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot reload: throw the controller out and re-create. Cheap on the new
    // path since native side rebuilds in milliseconds.
    final ctrl = _controller;
    _controller = null;
    ctrl?.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadInitial();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final gen = ++_loadGen;
    String dataStr;
    try {
      dataStr = await widget.data;
    } catch (e) {
      if (gen != _loadGen || !mounted) return;
      setState(() => _error = e);
      return;
    }
    if (gen != _loadGen || !mounted) return;
    if (dataStr.isEmpty) {
      setState(() => _error = StateError('empty Lottie data'));
      return;
    }

    final size = _resolvedSize();
    if (size == null) {
      // Layout not finished yet — try again next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _loadGen == gen) _loadInitial();
      });
      return;
    }
    final dpr = _resolvedDpr();
    final renderW = (size.width * dpr).round();
    final renderH = (size.height * dpr).round();
    if (renderW <= 0 || renderH <= 0) {
      setState(() => _error = StateError('non-positive render size'));
      return;
    }

    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(utf8.encode(dataStr));
    } catch (e) {
      if (gen != _loadGen || !mounted) return;
      setState(() => _error = e);
      return;
    }

    ThorvgController controller;
    try {
      controller = await ThorvgController.create(
        data: bytes,
        width: renderW,
        height: renderH,
        animate: widget.animate,
        repeat: widget.repeat,
        reverse: widget.reverse,
      );
    } on PlatformException catch (e) {
      if (gen != _loadGen || !mounted) return;
      setState(() => _error = e);
      return;
    } catch (e) {
      if (gen != _loadGen || !mounted) return;
      setState(() => _error = e);
      return;
    }

    if (gen != _loadGen || !mounted) {
      // Widget disposed or replaced while we were awaiting; clean up.
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _appliedDpr = dpr;
      _appliedWidth = size.width;
      _appliedHeight = size.height;
      _error = null;
    });
    widget.onLoaded?.call(controller);
  }

  Future<void> _maybeResize() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final size = _resolvedSize();
    if (size == null) return;
    final dpr = _resolvedDpr();
    if (size.width == _appliedWidth &&
        size.height == _appliedHeight &&
        dpr == _appliedDpr) {
      return;
    }
    final renderW = (size.width * dpr).round();
    final renderH = (size.height * dpr).round();
    if (renderW <= 0 || renderH <= 0) return;
    await ctrl.resize(renderW, renderH);
    if (!mounted) return;
    _appliedWidth = size.width;
    _appliedHeight = size.height;
    _appliedDpr = dpr;
  }

  Size? _resolvedSize() {
    if (widget.width > 0 && widget.height > 0) {
      return Size(widget.width, widget.height);
    }
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final s = box.size;
      final w = widget.width > 0 ? widget.width : s.width;
      final h = widget.height > 0 ? widget.height : s.height;
      if (w > 0 && h > 0) return Size(w, h);
    }
    return null;
  }

  double _resolvedDpr() {
    // Buffer is sized at `widget.renderScale × logical size`. We deliberately
    // don't read MediaQuery.devicePixelRatio here: with a SwCanvas backend,
    // letting the buffer track full DPR is the dominant cost when many
    // animations run on the shared render thread. Callers that need a
    // crisper image on retina screens can pass a higher `renderScale`.
    return widget.renderScale;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _placeholder(child: ErrorWidget(_error!));
    }
    final ctrl = _controller;
    if (ctrl == null) {
      return _placeholder();
    }
    return _placeholder(
      child: ClipRect(
        child: Texture(textureId: ctrl.textureId),
      ),
    );
  }

  Widget _placeholder({Widget? child}) {
    final w = widget.width > 0 ? widget.width : null;
    final h = widget.height > 0 ? widget.height : null;
    return SizedBox(width: w, height: h, child: child);
  }
}
