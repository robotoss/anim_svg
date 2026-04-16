# thorvg_plus — source-built thorvg for Flutter

`thorvg_plus` is a source-built fork of the [ThorVG Flutter runtime](https://github.com/thorvg/thorvg.flutter), published on pub.dev as a temporary workaround for [thorvg/thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22). Use it when you need thorvg to link on the iOS Simulator.

The public Dart API matches upstream `thorvg 1.0.0` byte-for-byte — `Lottie.asset`, `Lottie.network`, and everything else work the same way. Only the native build pipeline differs.

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
            Lottie.asset('assets/lottie/dancing_star.json'),
            Lottie.network(
              'https://lottie.host/6d7dd6e2-ab92-4e98-826a-2f8430768886/NGnHQ6brWA.json',
            ),
          ],
        ),
      ),
    );
  }
}
```

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
