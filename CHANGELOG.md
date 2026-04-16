## 0.0.2

* Switch runtime renderer from `thorvg: ^1.0.0` to our own source-built fork [`thorvg_plus: ^1.0.0`](https://pub.dev/packages/thorvg_plus). Fixes the iOS simulator linker error hit by pub.dev consumers (upstream [thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22)). No API changes to `AnimSvgView` / `AnimSvgController`.

## 0.0.1

* Initial experimental release.
* Pure-Dart SVG → Lottie JSON transpiler; rendering delegated to `package:thorvg` (native C++ renderer).
* Supported animation sources: SMIL (`<animate>`, `<animateTransform>`, `<animateMotion>`), CSS `@keyframes` (with motion path), and the Svgator `<script>` payload.
* Shape primitives (`<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polygon>`, `<polyline>`), gradients (linear/radial with animated stops), and Gaussian blur filter.
* `AnimSvgView.asset` / `AnimSvgView.string` widgets with `AnimSvgController`.
* Inline data-URI images; on-the-fly WebP → PNG transcode for thorvg compatibility.
