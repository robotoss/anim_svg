# anim_svg

**Animated SVG for Flutter, rendered by [thorvg](https://pub.dev/packages/thorvg).**

> ⚠️ **Experimental (0.0.1).** An attempt to bring animated SVG to Flutter by transpiling to Lottie JSON via a native Rust core and delegating rasterisation to the native C++ **thorvg** renderer. No custom SVG runtime.

---

## Pipeline

```text
┌──────────────────────────────────────────┐   ┌────────────────────┐   ┌─────────────────────┐
│  SVG                                     │   │  Transpiler        │   │  thorvg             │
│   • SMIL (<animate>, <animateTransform>) │──▶│  native Rust core  │──▶│  (native C++        │
│   • CSS @keyframes                       │   │  (anim_svg_core,   │   │   Lottie renderer)  │
│   • Svgator <script> payload             │   │   via raw dart:ffi)│   │                     │
└──────────────────────────────────────────┘   │  → Lottie JSON     │   └─────────────────────┘
                                               └────────────────────┘
```

Conversion runs entirely inside `native/anim_svg_core` (Rust) and is
invoked through `dart:ffi`. See [ADR-024](brain/adr.md#adr-024-native-rust-core-via-raw-dart-ffi-anim_svg_core)
for the rationale.

## Why

Flutter has no first-class rendering path for SMIL or CSS-animated SVG. Lottie does, and **thorvg** is a fast, actively maintained C++ Lottie renderer shipped to Flutter via [`package:thorvg`](https://pub.dev/packages/thorvg). `anim_svg` bridges the gap: it reads the animated SVG, emits a Lottie 5.7 document, and hands it to thorvg.

## Install

```bash
flutter pub add anim_svg
```

## Usage

### Widget

```dart
import 'package:anim_svg/anim_svg.dart';

AnimSvgView.asset(
  'assets/sticker.svg',
  width: 300,
  height: 300,
  controller: AnimSvgController(),
);
```

Also available: `AnimSvgView.string(svgXml, ...)` for in-memory SVG.

### Direct conversion

```dart
import 'package:anim_svg/anim_svg.dart';

final lottieMap  = ConvertSvgToLottie().convertToMap(svgXmlString);
final lottieJson = ConvertSvgToLottie().convertToJson(svgXmlString);
```

## Supported input

### Animation sources

| Source | Coverage |
| --- | --- |
| SMIL `<animate>`, `<animateTransform>`, `<animateMotion>`, `<set>` | Full MVP — translate/scale/rotate, opacity, display, path morph, motion path |
| `keyTimes`, `keySplines`, `calcMode="spline" \| "discrete"` | Full |
| CSS `@keyframes` + `animation:` shorthand | Full — `timing-function`, `delay`, `direction`, `fill-mode`, compound selectors |
| CSS `offset-path` / `offset-distance` / `offset-rotate` | Motion path → translate + rotate tracks |
| Svgator `<script>` payload | Opacity, path morph, transform (translate/scale/rotate with pivot compensation), `stroke-dashoffset`, `stroke-dasharray` |

### Graphics

| Feature | Lottie target |
| --- | --- |
| `<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polygon>`, `<polyline>` | `sh` / `rc` / `el` shape layers |
| Solid fills, strokes | `fl` / `st` |
| `<linearGradient>` / `<radialGradient>` (incl. animated stops) | `gf` with keyframed stops |
| `<filter>` + `feGaussianBlur` | Lottie Gaussian Blur effect (`ty:29`) |
| `<feComponentTransfer>` (`slope`) | Brightness & Contrast effect (`ty:22`) |
| `<image>` (inline data URI, PNG/JPEG) | Lottie asset with `e:1` |
| `<image>` (inline data URI, WebP) | Transcoded to PNG (see below) |
| `<defs>` + `<use xlink:href>` | Flattened before mapping |

### WebP → PNG transcode

thorvg 1.0's Flutter build ships loaders for Lottie, PNG, and JPEG — **not WebP**. When the SVG contains `data:image/webp;base64,...`, `anim_svg` decodes and re-encodes as PNG before embedding it in the Lottie asset. PNG and JPEG pass through untouched.

## Limitations

* External `<image href="…">` (non-data-URI) is not fetched.
* Non-blur SVG filters (`feColorMatrix`, most primitives) emit a warning and are skipped.
* Svgator's obfuscated payload fields (`s:"MDLA…"`) are ignored — keyframes are read from the plain JSON portion.
* Lottie 5.7 is the only serialisation target; no bodymovin-compatible effects beyond the table above.

## Example

```bash
cd example
flutter run
```

`example/` contains six representative SVGs exercising SMIL, CSS `@keyframes`, Svgator, gradients, and filters.

## Contributing

Issues and PRs welcome: <https://github.com/zoxo-outlook/anim_svg/issues>

## License

MIT © 2026 Yeftifeyev Konstantin — see [LICENSE](LICENSE).
