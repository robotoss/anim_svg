<h1 align="center">anim_svg</h1>

<p align="center">
  <em>Animated SVG for Flutter — transpiled to Lottie, rendered by <a href="https://www.thorvg.org/">thorvg</a>.</em>
</p>

<p align="center">
  <a href="https://pub.dev/packages/anim_svg"><img src="https://img.shields.io/pub/v/anim_svg.svg" alt="pub version"></a>
  <a href="https://pub.dev/packages/anim_svg/score"><img src="https://img.shields.io/pub/likes/anim_svg" alt="pub likes"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20Android-lightgrey.svg" alt="platforms">
  <img src="https://img.shields.io/badge/flutter-%E2%89%A53.24-02569B.svg" alt="Flutter ≥3.24">
  <img src="https://img.shields.io/badge/status-experimental-orange.svg" alt="experimental">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

`anim_svg` turns an animated SVG — SMIL, CSS `@keyframes`, motion paths — into a Lottie 5.7 document at runtime and hands the result to [**thorvg**](https://www.thorvg.org/), a fast C++ vector + Lottie renderer. It's shipped to Flutter via [`package:thorvg_plus`](https://pub.dev/packages/thorvg_plus) — a source-built fork of `package:thorvg` that restores iOS simulator support (see *[Why `thorvg_plus`](#why-we-depend-on-thorvg_plus-instead-of-thorvg)* below). Conversion runs entirely inside a native Rust core (`anim_svg_core`) invoked through `dart:ffi`.

> **Experimental (v0.0.4).** Public API may change between patch releases. Coverage grows with real-world input — if an SVG renders wrong, **open an issue with the file attached** and we'll add it to the fixture suite.

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

### Why we depend on `thorvg_plus` instead of `thorvg`

Upstream [`thorvg: ^1.0.0`](https://pub.dev/packages/thorvg) on pub.dev ships a device-only `libthorvg.dylib` for iOS, so any consumer building for the iOS simulator hits a linker error (tracked at [thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22)). `dependency_overrides` work only in the root app, **not transitively from a plugin** — so `anim_svg` can't fix this for its consumers by overriding upstream `thorvg` internally.

Instead we depend on [`thorvg_plus`](https://pub.dev/packages/thorvg_plus), a source-built fork published from this same repository. `thorvg_plus` compiles ThorVG per-platform (no prebuilt dylib at all), so the right architecture slice is always produced. The Dart API matches upstream byte-for-byte — only the native build pipeline differs.

We will migrate back to upstream `thorvg` as soon as #22 is resolved and a fixed version reaches pub.dev.

### Native binaries

`anim_svg` ships a Rust core that targets iOS and Android. The published package does **not** embed prebuilt binaries (they'd blow past pub.dev's 100 MB limit). Instead:

1. **Default path (zero setup).** On first `pod install` / Gradle build, the plugin's `prepare_command` downloads prebuilt artifacts for the current plugin version from [GitHub Releases](https://github.com/robotoss/anim_svg/releases) and verifies them via SHA256. No Rust toolchain required.
2. **Fallback path (source build).** If the download fails (offline, corporate firewall, missing release asset) the plugin falls back to building from the Rust source that ships with the package. See the **Building from source** section below for toolchain requirements.

Environment variables:

| Variable | Effect |
| --- | --- |
| `ANIM_SVG_SKIP_DOWNLOAD=1` | Skip the remote fetch, go straight to local build. Useful behind corporate proxies. |
| `FORCE_RUST_REBUILD=1` | Ignore any cached or downloaded artifacts and rebuild from source. |
| `ANIM_SVG_RELEASE_BASE_URL` | Override the release host (for mirrors / self-hosting). |

### Building from source

Only needed if the download path is disabled or unreachable. Requires a working Rust toolchain ([rustup.rs](https://rustup.rs)).

**Android:** install the NDK via Android Studio and make sure [`cargo-ndk`](https://github.com/bbqsrc/cargo-ndk) is on your `PATH` (`cargo install cargo-ndk`). Gradle invokes it automatically during build.

**iOS:** install Xcode, then add the iOS Rust targets once:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

CocoaPods runs the Rust build script during `pod install`.

### Swift Package Manager (iOS, `AnimSvgView.network` only)

`AnimSvgView.network` depends on `flutter_cache_manager`, whose transitive `path_provider_foundation` needs **Swift Package Manager** to link its ObjC runtime on iOS. Enable SPM once per machine; Flutter then integrates SPM into your Xcode project automatically alongside CocoaPods:

```bash
flutter config --enable-swift-package-manager
```

Without this flag iOS will crash at startup with `Couldn't resolve native function 'DOBJC_initializeApi'` the first time `AnimSvgView.network` is built. You don't need SPM if you only use `AnimSvgView.asset` / `.string`.

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

### Performance tuning: `renderScale`

The thorvg renderer is software-only (CPU SwCanvas), so rasterization cost scales with the rendered pixel count. Every factory accepts an optional `renderScale` (default `1.0`) — a multiplier applied to logical `width` / `height` when sizing the native render buffer.

```dart
AnimSvgView.network(
  url,
  width: 300,
  height: 300,
  renderScale: 1.0, // default: render at logical pixels — cheapest
);

AnimSvgView.network(
  url,
  width: 300,
  height: 300,
  renderScale: 2.0, // crisper on retina, ~4× more rasterization cost
);
```

| `renderScale` | When to use |
| --- | --- |
| `1.0` (default) | Many simultaneous animations, scrollable lists, low-end Android. Output is upscaled by Flutter's compositor; expect visible softness on high-DPR screens. |
| `1.5` – `2.0` | Hero animations, single visible item, high-DPR target. Costs ~2.25–4× more CPU per frame than the default. |
| device DPR (≈ 2.5–3.0) | Crispest output. Only feasible for one or two simultaneous animations on modern hardware. |

The native render path runs on a single shared producer thread (Android `HandlerThread`, iOS `DispatchQueue`) so the Flutter UI isolate is never blocked, but lifting `renderScale` past what the producer thread can sustain causes dropped frames in the Texture compositor — animations stutter visually even though the UI thread stays at 60 FPS. When in doubt, profile.

#### How `width` and `height` actually affect cost

Worth knowing for portrait-source SVGs (most slot-machine and mobile-app art): thorvg scales the source by `height / source_height`, leaving lateral padding on either side when `width` is wider than `source_width × scale`. **`height` therefore drives effectively all rasterization cost (∝ `height²` for square widget bounds); changing `width` only resizes the side padding** of the buffer.

This means:
- Match `width` to `(source_aspect × height)` to avoid wasted padding.
- Capping `height` is the single most effective lever when you need to fit more animations on screen at 60 FPS.

### Off-screen disposal

Each mounted `AnimSvgView` holds a thorvg scene tree, an RGBA frame buffer (`renderScale² × W × H × 4` bytes — ≈720 KB for a 300×300 tile at `renderScale: 2.0`), and a platform texture surface. Inside long lists this adds up quickly.

By default `AnimSvgView` watches its own viewport visibility and tears down the native handle once the widget has been fully off-screen for `disposeDelay`, then re-creates it after `showDelay` of returning to visibility — symmetric debounce that keeps fast scrolls from churning native resources.

```dart
AnimSvgView.network(
  url,
  width: 300,
  height: 300,
  // Defaults shown here for clarity; you can omit them.
  disposeWhenInvisible: true,
  disposeDelay: const Duration(milliseconds: 700),
  showDelay: const Duration(milliseconds: 150),
);
```

On Android the texture lifecycle is driven by `TextureRegistry.createSurfaceProducer` (since `thorvg_plus 1.1.0`). On API 28+ this is backed by `ImageReader` / `HardwareBuffer`, so create/destroy cycles stay cheap even under sustained fast-scroll workloads. On API < 28 the engine transparently falls back to `SurfaceTexture` — fine for typical use, but very long fast-scroll sessions on those older devices can in principle hit the legacy `BufferQueue` fence-FD pressure documented in [flutter/flutter#94916](https://github.com/flutter/flutter/issues/94916). If you observe FD growth in `/proc/<pid>/fd` during long scrolls on those targets, opt out via `disposeWhenInvisible: false`.

Tuning:

| Knob | When to change |
| --- | --- |
| `disposeWhenInvisible: false` | Keep the native handle alive while the widget stays mounted. Useful for tests, golden snapshots, tightly-scoped lists where every item is on-screen at rest, or as a safety opt-out on Android API < 28 (see above). |
| `disposeDelay` (lower, e.g. 200 ms) | Memory-constrained device or very long lists — reclaim sooner at the cost of more re-create churn during scrolling. |
| `disposeDelay` (higher, e.g. 1500 ms) | User scrolls the list back and forth a lot; mask the small re-mount cost behind a longer grace window. |
| `showDelay` (lower, e.g. 0 ms) | Fewer than ~10 simultaneous animations and you want the snappiest re-show; you accept paying one MethodChannel round-trip per fleeting scroll glance. |

Limitations:

- Visibility is detected geometrically against the viewport. **Items obscured by a `Stack` overlay in the same layer tree are NOT considered invisible** — the overlay covers them on screen but they're still painted underneath. If your UI flips between full-screen pages with a `Stack`, wrap the underlay branch in `Offstage` or `Visibility(visible: false)` at the call site to take it out of the tree entirely; that triggers our normal unmount path.
- `TabBarView` inactive tabs *are* handled — we treat `TickerMode.of(context) == false` the same as zero visibility.
- Re-showing pays roughly one MethodChannel `create` round-trip plus thorvg's per-instance native init. The Lottie JSON bytes are reused from the outer State, so no re-conversion happens.

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
- `data:image/webp;base64,...` — decoded with pure-rust [`image-webp`](https://crates.io/crates/image-webp) and re-encoded as PNG before handing to thorvg (thorvg 1.0's Flutter build ships PNG/JPG loaders only). On decode failure the original URI is kept, a warning is logged under `map.raster`, and that asset renders blank — the rest of the document still converts.
- External `href="http(s)://..."` — **not fetched**. Conversion fails with `UnsupportedFeatureException` by design.

### Lottie output

Schema 5.7. Layer types emitted: image (`ty:2`), null (`ty:3`), shape (`ty:4`). Shape items emitted: `sh`, `rc`, `el`, `fl`, `st`, `gf`, `tm`, `tr`, `gr`.

## Svgator

Svgator-exported SVGs embed a `<script>` tag containing a JavaScript runtime. **`anim_svg` does not execute that script** — a static transpiler can't faithfully emulate a JS engine, and partial parsing would produce wrong animation timing more often than right.

If you need to render Svgator output, use [Svgator's own Flutter-compatible Dart package](https://www.svgator.com/help/articles/can-i-use-svgator-with-flutter) — per their docs it ships native Dart support. Happy path: animate everything else with `anim_svg`, drop Svgator-exported assets through their SDK.

## The `thorvg.flutter/` directory

This repo hosts the source of our [`thorvg_plus`](https://pub.dev/packages/thorvg_plus) fork under `thorvg.flutter/`. It's published to pub.dev as a separate package (`cd thorvg.flutter && dart pub publish`) and consumed by `anim_svg` like any other hosted dependency. See the fork's own [README](thorvg.flutter/README.md) for what was changed and why.

Once upstream [thorvg/thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22) ships a fix, `anim_svg` will depend on upstream `thorvg` directly, `thorvg_plus` will be deprecated, and the `thorvg.flutter/` directory will be removed. Huge thanks to the thorvg team — the bug is narrow, the renderer itself is excellent.

## Example

```bash
cd example
flutter run
```

`example/` ships six representative fixtures exercising SMIL, CSS `@keyframes`, gradients, filters, and inline images — a good starting point for eyeballing conversion results.

## Contributing

**The single most useful thing you can do:** when an SVG breaks, open an issue and attach the file. Every accepted fixture becomes a permanent regression test and usually unlocks a small feature for every other user.

- Bugs / unsupported features → [open an issue](https://github.com/robotoss/anim_svg/issues) with the SVG attached and a one-liner on expected behavior.
- PRs adding element, SMIL, CSS, or filter mappings are welcome — update the matrix in this README in the same PR.
- Dev setup: install Rust + `cargo-ndk`, then `tool/prepare_rust.sh ios|android` builds the native core. Architecture notes live in [`brain/adr.md`](brain/adr.md) (ADR-024 covers the Rust core).

## Acknowledgements

- **[thorvg](https://www.thorvg.org/)** ([GitHub](https://github.com/thorvg/thorvg) · upstream [pub.dev](https://pub.dev/packages/thorvg)) — fast, actively maintained C++ vector + Lottie renderer. None of this exists without it. `anim_svg` currently links against our [`thorvg_plus`](https://pub.dev/packages/thorvg_plus) fork (see above).
- **Lottie** / [bodymovin](https://github.com/airbnb/lottie-web) — the format that makes animated vector portable.
- [`package:xml`](https://pub.dev/packages/xml), [`package:image`](https://pub.dev/packages/image), [`package:ffi`](https://pub.dev/packages/ffi) — the Dart side's load-bearing libraries.
- [`flutter_cache_manager`](https://pub.dev/packages/flutter_cache_manager) and [`http`](https://pub.dev/packages/http) — power the disk cache and network loader behind `AnimSvgView.network`.

## License

MIT © 2026 Yeftifeyev Konstantin — see [LICENSE](LICENSE).
