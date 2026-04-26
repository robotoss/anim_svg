/*
 * Copyright (c) 2024 - 2026 ThorVG project. All rights reserved.
 *
 * Licensed under the MIT License (see project LICENSE for details).
 */

import 'dart:async';

import 'package:flutter/services.dart';

/// Method-channel-backed controller for one Lottie animation rendered into
/// a Flutter `Texture(textureId)`.
///
/// Replaces the legacy `dart:ffi`-driven `Thorvg` class for jank-sensitive
/// callers. All rasterization happens on a native producer thread (per-texture
/// `HandlerThread` on Android, `DispatchQueue` on iOS); the Flutter UI isolate
/// only sends control messages — `play`, `pause`, `seek`, `resize`, `dispose`.
///
/// The controller is created via [ThorvgController.create]. It owns the
/// native handle and the registered `SurfaceTextureEntry` / `FlutterTexture`
/// behind [textureId]. Pass that id to a `Texture(textureId: …)` widget to
/// display the output.
class ThorvgController {
  ThorvgController._({
    required this.textureId,
    required this.lottieWidth,
    required this.lottieHeight,
    required this.totalFrame,
    required this.duration,
  });

  static const MethodChannel _channel = MethodChannel('thorvg_plus/texture');

  /// Texture id to pass to a `Texture` widget.
  final int textureId;

  /// Native lottie composition size (from Lottie JSON `w` / `h`).
  final int lottieWidth;
  final int lottieHeight;

  /// Animation length in frames; 0 for static lottie.
  final double totalFrame;

  /// Animation length in seconds.
  final double duration;

  bool _disposed = false;

  /// True after [dispose] has been called or the underlying texture has been
  /// torn down by the engine. Subsequent calls become no-ops.
  bool get isDisposed => _disposed;

  /// Creates a new texture-backed Lottie animation natively.
  ///
  /// [width] / [height] are the rasterization dimensions in device pixels —
  /// thorvg renders straight into a buffer of this size, so callers should
  /// already have applied the device pixel ratio.
  static Future<ThorvgController> create({
    required Uint8List data,
    required int width,
    required int height,
    bool animate = true,
    bool repeat = true,
    bool reverse = false,
    double speed = 1.0,
  }) async {
    if (data.isEmpty) {
      throw ArgumentError.value(data, 'data', 'must not be empty');
    }
    if (width <= 0 || height <= 0) {
      throw ArgumentError('width and height must be > 0 (got ${width}x$height)');
    }

    final raw = await _channel.invokeMapMethod<Object?, Object?>('create', {
      'data': data,
      'width': width,
      'height': height,
      'animate': animate,
      'repeat': repeat,
      'reverse': reverse,
      'speed': speed,
    });
    if (raw == null) {
      throw StateError('thorvg_plus.create returned null');
    }
    return ThorvgController._(
      textureId: (raw['textureId'] as num).toInt(),
      lottieWidth: (raw['lottieWidth'] as num?)?.toInt() ?? width,
      lottieHeight: (raw['lottieHeight'] as num?)?.toInt() ?? height,
      totalFrame: (raw['totalFrame'] as num?)?.toDouble() ?? 0.0,
      duration: (raw['duration'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Resumes (or starts) the animation. Idempotent.
  Future<void> play() => _invoke('play');

  /// Pauses the animation; the texture keeps its last rendered frame.
  /// Combine with `VisibilityDetector` to free CPU for off-screen items.
  Future<void> pause() => _invoke('pause');

  /// Seeks to [frame] (a value between 0 and [totalFrame]) and pauses.
  Future<void> seek(double frame) => _invoke('seek', {'frame': frame});

  /// Reallocates the native rasterization buffer to the new dimensions and
  /// renders the current frame at the new resolution.
  Future<void> resize(int width, int height) =>
      _invoke('resize', {'width': width, 'height': height});

  /// Releases the native handle, the SurfaceTexture/CVPixelBuffer pool, and
  /// the per-instance render thread. Must be called from the consuming
  /// widget's `dispose`.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod<void>('dispose', {'textureId': textureId});
    } catch (_) {
      // Native side already released — swallow to keep widget dispose safe.
    }
  }

  Future<void> _invoke(
    String method, [
    Map<String, Object?> extra = const {},
  ]) async {
    if (_disposed) return;
    final args = <String, Object?>{'textureId': textureId, ...extra};
    await _channel.invokeMethod<void>(method, args);
  }
}
