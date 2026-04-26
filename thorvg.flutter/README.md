# thorvg_plus — source-built thorvg for Flutter

`thorvg_plus` is a source-built fork of the [ThorVG Flutter runtime](https://github.com/thorvg/thorvg.flutter), published on pub.dev as a temporary workaround for [thorvg/thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22). Use it when you need thorvg to link on the iOS Simulator.

The `Lottie.*` factory constructors keep their upstream signatures — the migration from `package:thorvg` is drop-in. Internally the rendering pipeline has been moved off the Flutter UI isolate onto a native producer thread that pushes frames into a `Texture(textureId)` widget; see [Rendering pipeline](#rendering-pipeline) below.

## Why this fork exists

Upstream [`thorvg: ^1.0.0`](https://pub.dev/packages/thorvg) on pub.dev ships a **device-only** `libthorvg.dylib`. Any consumer running `flutter run -d <iOS simulator>` hits a linker error:

```
Building for 'iOS-simulator', but linking in dylib
  (…/pub.dev/thorvg-1.0.0/ios/Frameworks/libthorvg.dylib) built for 'iOS'
```

A local app can work around this with `dependency_overrides: thorvg: path: …`, but **overrides are not transitive through pub.dev** — a plugin that depends on `thorvg` cannot fix the problem for its own consumers.

`thorvg_plus` removes the prebuilt dylib entirely and builds ThorVG from source on every install, so the compiler produces the right slice for whatever the consumer is targeting.

## Scope

The pruned ThorVG tree shipped in this package keeps only what `Lottie.*` needs at runtime:

- **Loaders:** `lottie`, `png`, `jpg`, `raw`.
- **Renderer:** software engine only.

Removed (via [`tool/prune_thorvg.sh`](tool/prune_thorvg.sh)): SVG / TTF / WebP loaders, GL / WebGPU renderers, savers, tests.

## Relation to upstream

- Source: [thorvg/thorvg.flutter](https://github.com/thorvg/thorvg.flutter), tagged at `1.0.0`.
- Tracking bug: [thorvg.flutter#22 — iOS simulator linker failure](https://github.com/thorvg/thorvg.flutter/issues/22).
- Licence: MIT, unchanged — all copyright notices are preserved verbatim.

When upstream lands a fix and releases a patched `thorvg`, this package will be deprecated in favour of the official one. Switch back as soon as you can — the upstream is the actively maintained renderer.

## Install

```bash
flutter pub add thorvg_plus
```

## Usage

```dart
import 'package:thorvg_plus/thorvg.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Lottie.asset(
              'assets/lottie/dancing_star.json',
              width: 200,
              height: 200,
            ),
            Lottie.network(
              'https://lottie.host/6d7dd6e2-ab92-4e98-826a-2f8430768886/NGnHQ6brWA.json',
              width: 200,
              height: 200,
            ),
          ],
        ),
      ),
    );
  }
}
```

### Rendering pipeline

`Lottie.*` no longer rasterizes on the Flutter UI isolate. It renders into a Flutter `Texture(textureId)` driven by a native producer thread:

- **Android**: a shared `HandlerThread` per Flutter engine drives the `frame → update → render → ANativeWindow blit` pipeline through a JNI bridge into the existing `TvgLottieAnimation`.
- **iOS**: a shared serial `DispatchQueue` plus a `CVPixelBufferPool` (3-deep) feeds a `FlutterTexture`.

A single shared producer thread is used per platform (instead of one per Lottie) because thorvg's internal `ScopedLock` is a no-op while `TaskScheduler::threads() == 0`, leaving global state (`LoaderMgr`, `Initializer` refcount) unprotected against concurrent loads. The single-thread design serializes those calls without giving up the main goal — keeping the Flutter UI isolate free.

The shared SwCanvas is configured with NEON SIMD on ARM ABIs, `Initializer::init(4)` for parallel scanline rasterization, and `EngineOption::SmartRender` for partial redraws of static-heavy compositions.

### `renderScale`

Every `Lottie` factory accepts a `renderScale` parameter (default `1.0`) controlling how many physical pixels are rasterized per logical pixel of the widget. Software rasterization cost scales with the pixel count, so this is the single biggest perf lever.

```dart
Lottie.network(url, width: 300, height: 300, renderScale: 1.0); // default — cheapest
Lottie.network(url, width: 300, height: 300, renderScale: 2.0); // crisper, ~4× cost
```

Bump `renderScale` per call site when crispness matters more than headroom; lower it (or leave it at `1.0`) when many animations share the screen.

### `ThorvgController`

The `onLoaded` callback now hands back a `ThorvgController` (replacing the legacy direct-FFI `Thorvg` handle). It exposes a small async API backed by the platform's MethodChannel:

```dart
Lottie.network(
  url,
  width: 300,
  height: 300,
  onLoaded: (controller) async {
    // controller.totalFrame, controller.duration, controller.lottieWidth …
    await controller.pause();
    await controller.seek(0);
    await controller.play();
  },
);
```

The widget owns the controller's lifetime — it is disposed automatically when the widget is unmounted; calling `dispose()` manually is safe but unnecessary. The legacy direct-FFI `Thorvg` class remains exported for backward compatibility but is no longer used by `Lottie.*`.

## Platforms

| Platform | Architectures |
| --- | --- |
| Android | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| iOS     | `arm64` (device + simulator), `x86_64` (simulator) |

## Regenerate Flutter bindings

Only needed if you modify `tvgFlutterLottieAnimation.{h,cpp}`:

```sh
flutter pub get
flutter pub run ffigen --config ffigen.yaml
```

## License

MIT — see [LICENSE](LICENSE). © ThorVG Project.
