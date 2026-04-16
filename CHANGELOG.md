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
