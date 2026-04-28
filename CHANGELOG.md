## 0.0.5

* **Fixed**: Android 15+ 16 KB page size compatibility. The native `libanim_svg_core.so`
  (Rust) and `libthorvg.so` (C++, via `thorvg_plus 1.1.1`) now ship with `LOAD`
  segments aligned to 16384 bytes, so they load directly on devices using 16 KB
  memory pages instead of falling back to page-size-compat mode. Required for
  Play Console submissions targeting `targetSdk >= 35` after Nov 2025
  ([developer.android.com/16kb-page-size](https://developer.android.com/16kb-page-size)).
* Bumped `thorvg_plus` constraint to `^1.1.1`.
* Pinned plugin `ndkVersion` to r27 (`27.0.12077973`) — the lowest NDK whose
  C/C++ toolchain defaults to 16 KB alignment.

## 0.0.4

* **Breaking**: minimum Flutter is now `>=3.24.0` (was `>=3.3.0`). Required for the
  `TextureRegistry.SurfaceProducer` API used by `thorvg_plus 1.1.0`.
* **Fixed**: long fast-scroll sessions on Android no longer crash the raster
  thread inside `SurfaceTexture.updateTexImage` with `error dup'ing fence fd`
  ([flutter/flutter#94916](https://github.com/flutter/flutter/issues/94916),
  [flutter-webrtc/flutter-webrtc#1948](https://github.com/flutter-webrtc/flutter-webrtc/issues/1948)).
  The fix lives in `thorvg_plus 1.1.0`'s migration from
  `TextureRegistry.createSurfaceTexture` to
  `TextureRegistry.createSurfaceProducer` — on API 28+ the engine now selects
  an `ImageReader`/`HardwareBuffer`-backed implementation that sidesteps the
  legacy `BufferQueue` fence-FD pipeline. API < 28 transparently falls back
  to `SurfaceTexture` (no regression).
* Bumped `thorvg_plus` constraint to `^1.1.0`.

## 0.0.3

* Render optimisation for lists with multiple concurrent animations:
  * New `startDelay` parameter on `AnimSvgView.asset` / `.string` / `.network`. While the delay is pending the widget renders its `loadingBuilder`; this lets callers stagger the initial `tvg.load` (synchronous `SwCanvas` setup + first software rasterisation) across frames instead of colliding them in a single frame. Stagger by `index * 20ms` in a `ListView.itemBuilder` to smooth the initial mount.
  * `AnimSvgView` now wraps its rendered output in `RepaintBoundary`, so the per-frame `setState` that thorvg_plus issues from its frame callback no longer invalidates the surrounding list/scroll subtree.

## 0.0.2

* Switch runtime renderer from `thorvg: ^1.0.0` to our own source-built fork [`thorvg_plus: ^1.0.0`](https://pub.dev/packages/thorvg_plus). Fixes the iOS simulator linker error hit by pub.dev consumers (upstream [thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22)). No API changes to `AnimSvgView` / `AnimSvgController`.

## 0.0.1

* Initial experimental release.
* Pure-Dart SVG → Lottie JSON transpiler; rendering delegated to `package:thorvg` (native C++ renderer).
* Supported animation sources: SMIL (`<animate>`, `<animateTransform>`, `<animateMotion>`), CSS `@keyframes` (with motion path), and the Svgator `<script>` payload.
* Shape primitives (`<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polygon>`, `<polyline>`), gradients (linear/radial with animated stops), and Gaussian blur filter.
* `AnimSvgView.asset` / `AnimSvgView.string` widgets with `AnimSvgController`.
* Inline data-URI images; on-the-fly WebP → PNG transcode for thorvg compatibility.
