## 1.1.1

* **Fixed**: Android 15+ 16 KB page size compatibility. `libthorvg.so` is now
  linked with `-Wl,-z,max-page-size=16384` and `-Wl,-z,common-page-size=16384`,
  so all `LOAD` segments are aligned to 16384 bytes. Devices using 16 KB
  memory pages (Android 15+) load the library directly instead of falling back
  to page-size-compat mode. Required for Play Console submissions targeting
  `targetSdk >= 35` after Nov 2025
  ([developer.android.com/16kb-page-size](https://developer.android.com/16kb-page-size)).

## 1.1.0

* **Breaking**: minimum Flutter is now `>=3.24.0` (was `>=3.3.0`).
* Migrated the Android `Texture`-based renderer from
  `TextureRegistry.createSurfaceTexture()` to
  `TextureRegistry.createSurfaceProducer()`. On API 28+ the engine selects an
  `ImageReader`/`HardwareBuffer`-backed implementation, sidestepping the
  `BufferQueue` fence-FD leak that crashed long-scroll sessions inside
  `SurfaceTexture.updateTexImage` (see [flutter/flutter#94916](https://github.com/flutter/flutter/issues/94916),
  [flutter-webrtc/flutter-webrtc#1948](https://github.com/flutter-webrtc/flutter-webrtc/issues/1948)).
  On API < 28 the engine transparently falls back to `SurfaceTexture` (no
  regression).
* `ThorvgTexture` now wires `SurfaceProducer.Callback` to handle engine-
  driven surface destroy/recreate cycles (e.g. backgrounding); the cached
  `ANativeWindow*` is detached on `onSurfaceDestroyed` and re-attached on
  `onSurfaceCreated`, with the last frame re-rendered to avoid a black
  re-show flash. No public API changes on the Dart side.

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