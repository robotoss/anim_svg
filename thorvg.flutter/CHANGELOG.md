## 1.0.0 — forked from thorvg 1.0.0

Initial release of `thorvg_plus`, a source-built fork of
[thorvg 1.0.0](https://pub.dev/packages/thorvg/versions/1.0.0) published
independently to address [thorvg.flutter#22](https://github.com/thorvg/thorvg.flutter/issues/22)
(iOS simulator linker failure caused by the device-only libthorvg.dylib
shipped by upstream).

Differences from upstream thorvg 1.0.0:
- iOS builds ThorVG from source via the CocoaPods podspec instead of
  consuming a prebuilt dylib. The resulting framework has both device
  and simulator slices, so `flutter run -d <simulator>` links correctly.
- Android builds via CMake NDK per-ABI (same as upstream source path).
- Pruned ThorVG tree: removed SVG/TTF/WebP loaders, GL/WebGPU renderers,
  savers, and tests. See `tool/prune_thorvg.sh`.
- No other API changes. The Dart `Lottie` widget and its constructors
  match upstream byte-for-byte.

Once upstream fixes #22 and releases a patched thorvg, this fork will
be deprecated in favour of the official package.

## Upstream history (thorvg 1.0.0)

* Update ThorVG to v1.0.0

## 1.0.0-pre.11

* Update ThorVG to v1.0.0-pre11

## 1.0.0-pre.10

* Update ThorVG to v1.0.0-pre10

## 1.0.0-pre.8

* Update ThorVG to v1.0.0-pre8
* Update binding to align canvas API with latest version

## 1.0.0-pre.7

* Update ThorVG to v1.0.0-pre7

## 1.0.0-pre.6

* Update ThorVG to v1.0.0-pre6

## 1.0.0-pre.5

* Update ThorVG to v1.0.0-pre5

## 1.0.0-pre.4

* Update ThorVG to v1.0.0-pre4

## 1.0.0-pre.3

* Update ThorVG to v1.0.0-pre3

## 1.0.0-pre.2

* Update ThorVG to v1.0.0-pre2

## 1.0.0-pre.1

* Update ThorVG to v1.0.0-pre1

## 1.0.0-beta.1

* Update ThorVG to v0.15.0

## 1.0.0-beta.0

* Introduce ThorVG flutter runtime (beta)
* Starting from ThorVG v0.14.10