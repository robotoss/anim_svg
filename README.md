<h1 align="center">anim_svg</h1>

<p align="center">
  <em>Animated SVG for Flutter — transpiled to Lottie, rendered by <a href="https://www.thorvg.org/">thorvg</a>.</em>
</p>

<p align="center">
  <a href="https://pub.dev/packages/anim_svg"><img src="https://img.shields.io/pub/v/anim_svg.svg" alt="pub version"></a>
  <a href="https://pub.dev/packages/anim_svg/score"><img src="https://img.shields.io/pub/likes/anim_svg" alt="pub likes"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20Android-lightgrey.svg" alt="platforms">
  <img src="https://img.shields.io/badge/flutter-%E2%89%A53.3-02569B.svg" alt="Flutter ≥3.3">
  <img src="https://img.shields.io/badge/status-experimental-orange.svg" alt="experimental">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

`anim_svg` turns an animated SVG — SMIL, CSS `@keyframes`, motion paths — into a Lottie 5.7 document at runtime and hands the result to [**thorvg**](https://www.thorvg.org/), a fast C++ vector + Lottie renderer shipped to Flutter via [`package:thorvg`](https://pub.dev/packages/thorvg). Conversion runs entirely inside a native Rust core (`anim_svg_core`) invoked through `dart:ffi`.

> **Experimental (v0.0.1).** Public API may change between patch releases. Coverage grows with real-world input — if an SVG renders wrong, **open an issue with the file attached** and we'll add it to the fixture suite.

---

## Why

Flutter has no first-class runtime for SMIL- or CSS-animated SVG. Lottie does, and [thorvg](https://github.com/thorvg/thorvg) is a production-grade open-source renderer that already ships it to Flutter. `anim_svg` bridges the gap: it reads the animated SVG, emits a valid Lottie JSON document, and lets thorvg do what it does best — draw it, fast.

## Pipeline

```text
┌──────────────────────────────────────────┐   ┌────────────────────┐   ┌─────────────────────┐
│  SVG                                     │   │  anim_svg_core     │   │  thorvg             │
│   • SMIL (<animate>, <animateTransform>) │──▶│  (native Rust,     │──▶│  (native C++        │
│   • CSS @keyframes + motion path         │   │   via dart:ffi)    │   │   Lottie renderer)  │
│   • Inline images (data URI)             │   │  → Lottie 5.7 JSON │   │                     │
└──────────────────────────────────────────┘   └────────────────────┘   └─────────────────────┘
```

The Rust core streams every stage (parse → map → serialize) through a structured log envelope, so nothing produced by the pipeline is dropped silently. See [ADR-024](brain/adr.md) for the design rationale.

## Supported platforms

| Platform | Status | Notes |
| --- | --- | --- |
| iOS 13+ | ✅ | arm64 device + simulator; static xcframework built from Rust |
| Android 24+ | ✅ | `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`; built via `cargo-ndk` + CMake |
| macOS / Linux / Windows | ⏳ | not attempted yet — contributions welcome |
| Web | ⏳ | not attempted yet — would require a WASM build of the Rust core |

## Install

```bash
flutter pub add anim_svg
```

Building the native core from source requires a working Rust toolchain ([rustup.rs](https://rustup.rs)).

**Android:** install the NDK via Android Studio and make sure [`cargo-ndk`](https://github.com/bbqsrc/cargo-ndk) is on your `PATH` (`cargo install cargo-ndk`). Gradle invokes it automatically during build.

**iOS:** install Xcode, then add the iOS Rust targets once:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

CocoaPods runs the Rust build script during `pod install`.

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

In-memory SVG:

```dart
AnimSvgView.string(svgXml, width: 240, height: 240);
```

Remote SVG (cached on disk for 7 days):

```dart
AnimSvgView.network(
  'https://example.com/sticker.svg',
  width: 300,
  height: 300,
  fit: BoxFit.contain,         // default; same semantics as Image
  alignment: Alignment.center, // default
  loadingBuilder: (ctx) => const CircularProgressIndicator(),
  errorBuilder: (ctx, err, stack) => const Icon(Icons.broken_image),
);
```

`fit` / `alignment` are accepted by **every** factory (`.asset`, `.string`, `.network`) and behave the same way as on `Image` — the rendered Lottie surface is wrapped in a `FittedBox` because thorvg itself paints at 1:1.

### Direct conversion (no widget)

```dart
import 'package:anim_svg/anim_svg.dart';

final converter  = ConvertSvgToLottie();
final lottieMap  = converter.convertToMap(svgXml);   // Map<String, dynamic>
final lottieJson = converter.convertToJson(svgXml);  // String
```

### Networking & caching

`AnimSvgView.network(url)` runs a tiny three-step pipeline:

1. **Cache lookup.** Ask `LottieCacheManager` (a `flutter_cache_manager` instance) for an entry keyed by the URL string. If a fresh entry exists, its bytes are returned immediately — no HTTP, no FFI.
2. **HTTP GET.** On a miss, fetch the SVG with `package:http`. Non-200 responses raise `NetworkSvgException(url, statusCode: …)` and are logged at `error` via the active `AnimSvgLogger` (defaults to `DeveloperLogger`).
3. **Convert + store.** Feed the SVG body to the Rust core (`ConvertSvgToLottie`) and write the resulting Lottie JSON into the cache.

What the cache stores and where:

| Property | Value |
| --- | --- |
| Payload | the **converted Lottie JSON** (not the raw SVG) — replays skip both the network and the FFI converter |
| Key | the URL string (one cached file per unique URL) |
| TTL | **7 days** (`Config.stalePeriod`) |
| Capacity | 200 entries, LRU eviction |
| Location | platform `getTemporaryDirectory()` — managed by `flutter_cache_manager` |
| Store key | `anim_svg_lottie_v2` — bumped if the converter output format changes |

Hooks for advanced cases:

```dart
// Pre-warm the cache at app start (no widget needed).
final loader = NetworkSvgLoader();
await loader.loadLottieBytes('https://example.com/hero.svg');

// Wipe everything (e.g. on user "Clear cache" action).
await LottieCacheManager.instance.emptyCache();

// Use a custom CacheManager for tests or stricter eviction.
AnimSvgView.network(url, width: 200, height: 200, cacheManager: myManager);
```

### Debugging

Plug a logger in and every stage of the pipeline streams back into your app's logs — including the network path (`network.fetch`, `network.cache.hit/store`) and `NetworkSvgException` (URL + status):

```dart
AnimSvgView.asset(
  'assets/sticker.svg',
  width: 300, height: 300,
  logger: DeveloperLogger(),
  onLottieReady: (bytes) {
    // Paste into https://lottiefiles.com/preview to isolate render vs. conversion issues.
  },
);
```

`DeveloperLogger` is the default if no logger is passed, so network failures (DNS, 404, parse) always surface in the `anim_svg` channel of DevTools / IDE console even with the silent `Icon(Icons.broken_image)` fallback.

## Supported input

The matrix below reflects what the Rust core actually emits today — no aspirational rows.

### SVG elements

| Recognized | Behavior |
| --- | --- |
| `<svg>`, `<g>`, `<defs>`, `<use>` | `<use>` resolves local `#id` refs; recursion depth ≤ 32 |
| `<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polyline>`, `<polygon>` | Emitted as Lottie shape layers (`sh` / `rc` / `el`) |
| `<linearGradient>`, `<radialGradient>`, `<stop>` | `gradientUnits`, `gradientTransform`, focal points, animated stops |
| `<filter>` | Only the primitives listed in the *Filters* table below |
| `<mask>` | Luminance + alpha matte, baked at t=0 |
| `<image>` | Inline `data:` URI only (see *Images*) |
| `<style>`, `<script>` | Parsed (`<style>` for CSS); `<script>` extracted but not executed |
| `<title>`, `<desc>`, `<metadata>`, `<clipPath>`, `<pattern>`, `<marker>`, `<symbol>` | Silently skipped (decorative or out-of-scope) |

### SMIL animation

| Element | Attributes supported |
| --- | --- |
| `<animate>` | `attributeName`, `dur`, `from` / `to` / `by` / `values`, `keyTimes`, `keySplines`, `calcMode` (`linear` \| `spline` \| `discrete` \| `paced`), `repeatCount="indefinite"`, `additive` |
| `<animateTransform>` | All of the above + `type` (`translate`, `scale`, `rotate`, `skewX`, `skewY`, `matrix`) |
| `<animateMotion>` | `path`, `values`, `keyPoints` / `keyTimes`, `rotate="auto \| auto-reverse \| Ndeg"` |

Not supported: `<set>`, `<mpath>`, explicit `begin` / `end` offsets.

### CSS animation

- `@keyframes name { 0%/from ... 100%/to ... }` including per-keyframe `animation-timing-function` overrides.
- Shorthand `animation:` and every longhand: `animation-name`, `animation-duration`, `animation-delay`, `animation-timing-function`, `animation-iteration-count`, `animation-direction`, `animation-fill-mode`.
- Timing functions: `linear`, `ease`, `ease-in`, `ease-out`, `ease-in-out`, `cubic-bezier(x1,y1,x2,y2)`, `step-start`, `step-end`, `steps(n)`.
- Selectors: `#id`, `.class`, and compound lists (`#a, #b, .c`).
- Whitelisted static properties: `fill`, `fill-opacity`, `opacity`.
- Keyframe properties: `transform`, `opacity`, `offset-distance`, `stroke-dashoffset`.

### Transforms

All 2D: `translate`, `translateX/Y`, `scale`, `scaleX/Y`, `rotate` / `rotateZ`, `skewX`, `skewY`, `matrix(a,b,c,d,e,f)`. `translate3d` and `scale3d` are tolerated (z ignored). `rotateX`, `rotateY`, `rotate3d` warn and skip. `transform-origin` accepts **pixel values only** — percentages and keywords (`center`, `top`) are not yet resolved.

### Motion path

CSS `offset-path: path('M…Z')`, `offset-distance`, `offset-rotate: auto | reverse | N(deg|rad|turn|grad)`. SMIL `<animateMotion>` with `path` data, `values` point lists, or `keyPoints` / `keyTimes` sampling. `ray()` and `url(#id)` motion path forms are not supported.

### Gradients

`<linearGradient>` and `<radialGradient>` with `gradientUnits` (`userSpaceOnUse` | `objectBoundingBox`), `gradientTransform`, and animated `<stop>` color / opacity. Radial focal points (`fx`, `fy`) are respected. Switching `fill` between gradient IDs at runtime is not supported.

### Filters → Lottie effects

| Filter primitive | Lottie output |
| --- | --- |
| `<feGaussianBlur stdDeviation>` (animatable) | Gaussian Blur (`ty:29`) |
| `<feComponentTransfer>` with R/G/B `type="linear" slope="N"` | Brightness & Contrast (`ty:22`) |
| `<feColorMatrix type="saturate" values>` (animatable) | Saturation (approximate — mapping still firming up) |
| Anything else (`feBlend`, `feOffset`, `feFlood`, `feDisplacementMap`, `feTurbulence`, …) | ⚠️ skipped with warning |

### Images

- `data:image/png;base64,...` — passes through verbatim.
- `data:image/jpeg;base64,...` — passes through verbatim.
- `data:image/webp;base64,...` — ⚠️ WebP decode/transcode is not yet implemented in the native core and will render blank.
- External `href="http(s)://..."` — **not fetched**. Conversion fails with `UnsupportedFeatureException` by design.

### Lottie output

Schema 5.7. Layer types emitted: image (`ty:2`), null (`ty:3`), shape (`ty:4`). Shape items emitted: `sh`, `rc`, `el`, `fl`, `st`, `gf`, `tm`, `tr`, `gr`.

## Svgator

Svgator-exported SVGs embed a `<script>` tag containing a JavaScript runtime. **`anim_svg` does not execute that script** — a static transpiler can't faithfully emulate a JS engine, and partial parsing would produce wrong animation timing more often than right.

If you need to render Svgator output, use [Svgator's own Flutter-compatible Dart package](https://www.svgator.com/help/articles/can-i-use-svgator-with-flutter) — per their docs it ships native Dart support. Happy path: animate everything else with `anim_svg`, drop Svgator-exported assets through their SDK.

## Why is `thorvg.flutter/` vendored?

This repo currently vendors a fork of [`thorvg.flutter`](https://github.com/thorvg/thorvg.flutter) under `thorvg.flutter/`. It carries a small C++ tweak needed for clean iOS builds, tracked upstream at **[thorvg/thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22)**. Once that issue lands upstream this package will depend on `thorvg` from pub.dev directly and the `thorvg.flutter/` directory will go away. Huge thanks to the thorvg team — the bug is narrow, the renderer itself is excellent.

## Example

```bash
cd example
flutter run
```

`example/` ships six representative fixtures exercising SMIL, CSS `@keyframes`, gradients, filters, and inline images — a good starting point for eyeballing conversion results.

## Contributing

**The single most useful thing you can do:** when an SVG breaks, open an issue and attach the file. Every accepted fixture becomes a permanent regression test and usually unlocks a small feature for every other user.

- Bugs / unsupported features → [open an issue](https://github.com/zoxo-outlook/anim_svg/issues) with the SVG attached and a one-liner on expected behavior.
- PRs adding element, SMIL, CSS, or filter mappings are welcome — update the matrix in this README in the same PR.
- Dev setup: install Rust + `cargo-ndk`, then `tool/prepare_rust.sh ios|android` builds the native core. Architecture notes live in [`brain/adr.md`](brain/adr.md) (ADR-024 covers the Rust core).

## Acknowledgements

- **[thorvg](https://www.thorvg.org/)** ([GitHub](https://github.com/thorvg/thorvg) · [pub.dev](https://pub.dev/packages/thorvg)) — fast, actively maintained C++ vector + Lottie renderer. None of this exists without it.
- **Lottie** / [bodymovin](https://github.com/airbnb/lottie-web) — the format that makes animated vector portable.
- [`package:xml`](https://pub.dev/packages/xml), [`package:image`](https://pub.dev/packages/image), [`package:ffi`](https://pub.dev/packages/ffi) — the Dart side's load-bearing libraries.
- [`flutter_cache_manager`](https://pub.dev/packages/flutter_cache_manager) and [`http`](https://pub.dev/packages/http) — power the disk cache and network loader behind `AnimSvgView.network`.

## License

MIT © 2026 Yeftifeyev Konstantin — see [LICENSE](LICENSE).
