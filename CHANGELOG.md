## 0.0.1

* Initial experimental release.
* Pure-Dart SVG → Lottie JSON transpiler; rendering delegated to `package:thorvg` (native C++ renderer).
* Supported animation sources: SMIL (`<animate>`, `<animateTransform>`, `<animateMotion>`), CSS `@keyframes` (with motion path), and the Svgator `<script>` payload.
* Shape primitives (`<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polygon>`, `<polyline>`), gradients (linear/radial with animated stops), and Gaussian blur filter.
* `AnimSvgView.asset` / `AnimSvgView.string` widgets with `AnimSvgController`.
* Inline data-URI images; on-the-fly WebP → PNG transcode for thorvg compatibility.
