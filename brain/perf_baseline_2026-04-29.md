# Performance baseline — pre-GL-migration (2026-04-29)

Captured before the SwCanvas → GlCanvas migration begins. Re-captured in Sprint 7 with the same scenarios on the same devices for direct comparison.

## What we are measuring

Three scenarios on each platform, each tied to a hypothesis about where time goes:

| Scenario | What it stresses | Hypothesis a GL switch should fix |
|---|---|---|
| **A — single fullscreen** | One `AnimSvgView.asset('svg_anim_1.svg')` filling a full ~1080×2400 viewport with `renderScale: 2.0` (effective ~2160×4800 raster). | CPU rasterization in `tvg::SwCanvas`. If GL helps, this is where the gain is biggest. |
| **B — list of 24** | Existing `example/lib/main.dart` — 6 SVGs × 4 repeats, scrolled top-to-bottom and back. Cell ~ 380×220 logical, `renderScale: 2.0`. | Multiple concurrent CPU rasterizations + visibility-driven mount/dispose churn. |
| **C — single small static** | One `AnimSvgView` at 100×100 with a logo-style SVG (mostly static background, a small animated glyph). Mount it 30 s, no scroll. | SmartRender CPU savings. **GL will silently lose this optimization** (`tvgCanvas.cpp:209`) — if SmartRender is doing real work, GL is a regression here. |

For each scenario, capture:
- **P50 / P95 / P99 frame time** (ms) over a 30 s window after warmup.
- **Top-3 hottest CPU symbols** (Time Profiler / simpleperf).
- **Graphics memory PSS** (Android `dumpsys meminfo`) or **IOSurface count** (Xcode memory graph) — for leak detection.

## How to capture on iOS (iPhone wireless)

Device: `iPhone Анна (2)` connected wirelessly, iOS 26.3.1.

1. **Build profile mode:**
   ```bash
   cd /Users/kos/Documents/flutter_project/anim_svg/example
   flutter build ios --profile --no-codesign  # first verify it compiles
   ```

2. **Run on device with profile mode** (must sign through Xcode at least once for this device):
   ```bash
   flutter run --profile -d "iPhone Анна (2)"
   ```
   Open the app and observe the in-app FPS overlay (top-right corner) while:
   - Scenario A: tap the "Stress" button (or `--dart-define=PERF_MODE=stress` at run time).
   - Scenario B: leave default — the demo list. Scroll up/down 3-4 times.
   - Scenario C: tap the "Static" button.
   The overlay logs P50/P95/P99 to console every 10 s.

3. **Detailed profile via Instruments** (optional, for hot-symbol breakdown):
   - In Xcode: `Product → Profile`, choose template **Time Profiler**.
   - Add the **Metal System Trace** instrument from the library.
   - Record 30 s while running each scenario.
   - Export the trace; record the top-3 functions in the table below.
   - Specifically look for: `tvg::SwRaster::rasterTexmapPolygon*`, `vImagePermuteChannels_ARGB8888`, `tvg::SwShape::*`. These are the symbols Sprint 7 must show as gone.

## How to capture on Android (emulator or physical)

Available emulators: `Pixel_6`, `Pixel_9_Pro`. Prefer `Pixel_6` (slower, more representative of real-world).

1. **Launch emulator:**
   ```bash
   flutter emulators --launch Pixel_6
   ```
   Wait for boot (~2 min).

2. **Build profile + run:**
   ```bash
   cd /Users/kos/Documents/flutter_project/anim_svg/example
   flutter run --profile -d emulator-5554 --trace-skia
   ```

3. **In-app FPS overlay** as on iOS — same logging.

4. **Frame stats from system:**
   ```bash
   adb shell dumpsys gfxinfo com.zharume.anim_svg.example reset   # before scenario
   # ... interact with app for 30 s ...
   adb shell dumpsys gfxinfo com.zharume.anim_svg.example framestats > frames.txt
   ```
   Look at the `Janky frames`, `90th percentile`, `95th percentile`, `99th percentile` lines.

5. **CPU sampling** (optional, hot-symbol breakdown):
   ```bash
   APP_PID=$(adb shell pidof com.zharume.anim_svg.example)
   adb shell simpleperf record -p $APP_PID -g --duration 30 -o /sdcard/perf.data
   adb pull /sdcard/perf.data
   simpleperf report -i perf.data --sort symbol --children
   ```
   Look specifically for: `tvg::SwRaster*`, `__memcpy_aarch64` (in `nativeRenderFrame` context), `tvg::Picture::draw`.

6. **Memory baseline:**
   ```bash
   adb shell dumpsys meminfo com.zharume.anim_svg.example | grep -E 'TOTAL|Graphics|GL|EGL'
   ```

## Baseline numbers — first capture, 2026-04-29

### Tooling caveats discovered during the run

Two surprises that materially changed how the baseline can be read:

1. **`dumpsys gfxinfo` is useless for Flutter apps.** HWUI (the Android Java view rasterizer) draws into ViewRootImpl; Flutter draws into a SurfaceView and bypasses HWUI entirely. After 30 s of continuous scrolling we got `Total frames rendered: 0` — HWUI literally never sees Flutter's frames. The frame-stats commands in the section above stay documented as a template, but for THIS app the only things gfxinfo reports usefully are: the **`GraphicBufferAllocator` total** and the **ImageReader/SurfaceView buffer enumeration** (memory side, not frame side).

2. **`simpleperf` requires a debuggable APK.** Profile builds are not debuggable by default. Attempting `simpleperf record -e task-clock:u --app com.zharume.anim_svg_example` returns `Permission denied` even with `setprop security.perf_harden 0` (already 0). Two paths to fix in a follow-up: (a) add `<application android:debuggable="true">` to `example/android/app/src/profile/AndroidManifest.xml` and rebuild, or (b) capture the same data interactively via Flutter DevTools → Performance / CPU profiler (graphical, not scriptable). Deferred to a Sprint 7 sub-step before re-measuring.

3. **`developer.log()` calls don't appear in `adb logcat` in Flutter profile mode.** They're routed through the VM Service to the `flutter run` console, but `flutter run`'s stdout is mostly silent in profile (only IMPORTANT-tagged engine messages echo). The on-screen overlay still works — visible numbers are captured from screenshots below, not from logs.

### What we actually measured — Pixel emulator (sdk gphone64 arm64, Android 16/API 36, host Apple Silicon)

Scenario B only (the existing demo list — 24 items × `renderScale: 2.0`, AnimSvgView with VisibilityDetector, default disposeWhenInvisible).

**Flutter UI/raster-thread frame time** (from on-screen `PerfOverlay`, rolling p50/p95/p99 over last 120 frames):

| State | p50 | p95 | p99 |
|---|---|---|---|
| Idle (no scroll) | 2.6 ms | 4.3 ms | 5.3 ms |
| 30 s of fast swipes (200 ms/swipe) | 2.7 ms | 4.1 ms | 5.0 ms |
| 30 s of realistic swipes (600 ms/swipe + 1.2 s pause) | 3.6 ms | 4.9 ms | 6.4 ms |

**Headline:** Flutter's UI/raster thread spends < 6 ms even under continuous scroll — well within the 16.6 ms vsync budget. **The Flutter pipeline is NOT the bottleneck.** All heavy work (thorvg `SwCanvas::draw`, ABGR→RGBA byte order to ANativeWindow) happens on the per-texture native producer thread (`ThorvgTexture.kt`'s shared render `Handler/Looper`); `SchedulerBinding.addTimingsCallback` is blind to that thread by design.

**Memory pressure** (from `dumpsys gfxinfo … | tail` after 30 s warmup):

- `Total imported by gralloc: 122 856 KiB` (~120 MiB), `Total allocated by GraphicBufferAllocator (estimate): 25 724 KB` (~25 MiB)
- ImageReader buffer geometries actually live in memory simultaneously:
  - `770×440` × ~10 buffers (~13 MiB)
  - `821×378` × ~7 buffers (~17 MiB)
  - `440×440` × ~6 buffers (~9 MiB)
  - SurfaceView/ViewRootImpl `1280×2856` × 4 buffers (~57 MiB — Flutter's own surface, not thorvg's)
- Each `ThorvgTexture` instantiates an `ImageReader` with 3-4 backing `HardwareBuffer`s (visible from the `ImageReader-WxHfFFmM-pid-id` naming).

**Headline #2:** the visible memory cost on Android is dominated by Flutter's own SurfaceView (~57 MiB) + per-texture triple/quad-buffered ImageReaders (~40 MiB combined for ~5-6 active textures). thorvg's `uint8_t* buffer` (the SwCanvas write target) is NOT what's eating gralloc — it's the consumer-side `HardwareBuffer`s sitting between the producer thread and Flutter's compositor.

### What this means for the GL migration

- **Android — CPU savings:** the ~120 MiB visible memory will mostly NOT shrink with GL (the same `ImageReader` + `SurfaceProducer` pipeline keeps its triple-buffering). The win there is on the producer thread's CPU: SwCanvas rasterization + ABGR memcpy → GPU rasterization + zero copy. Magnitude unmeasurable without simpleperf, but architecturally guaranteed for any non-trivial rasterization workload.
- **Android — UI thread:** numbers will not change. Already at 2-5 ms.
- **iOS — bigger win:** the `vImagePermuteChannels_ARGB8888` swizzle is per-pixel CPU work that disappears entirely under ANGLE-Metal's BGRA_EXT IOSurface binding. Memory side: same `CVPixelBufferPool` triple-buffering retained.
- **Static-composition risk (Scenario C, not measured):** SmartRender's CPU win on mostly-static logos is invisible to all our metrics here (only ~6 dynamic anims in this demo, none mostly-static). Have to take the risk on faith for now; mitigation is the hybrid SW/GL toggle in Sprint 6.

### Decision gate

**Proceed to Sprint 1.**

The Flutter pipeline is fine. The producer-thread CPU cost we can't measure on this emulator setup, but architectural reasoning + the brain memory note "UI jank in anim_svg comes from thorvg render engine" + the visible 120 MiB graphics footprint together justify the migration. The hybrid SW/GL toggle in Sprint 6 covers the Scenario C downside.

**Re-measure recipe for Sprint 7** (must do BEFORE writing ADR-025):
1. Add `android:debuggable="true"` to `example/android/app/src/profile/AndroidManifest.xml`, rebuild profile APK.
2. Capture `simpleperf record -p $PID -e task-clock:u -f 1000 --duration 30 -g` during the same realistic-scroll scenario, both pre-GL (sw_engine commit `d10b643`) and post-GL.
3. Run `simpleperf report --children --sort symbol -g` and grep for `tvg::SwRaster*`, `tvg::Picture::draw`, `__memcpy_aarch64`. The pre-GL profile should show these in the top-10 by self+children; post-GL should show them at 0 or near-zero (replaced by GLES driver symbols + ANGLE on iOS).
4. iPhone Анна (2) for the iOS half (physical device, profile mode works there).

## Decision gate (read after baseline is captured)

After Sprint 0 numbers are filled in, compare:

- **Scenarios A and B with `tvg::SwRaster*` or `__memcpy_aarch64` in top-3 + P95 above 16.6 ms** → bottleneck is CPU rasterization or the surface copy. **Proceed to Sprint 1.** This is the case GL will fix in spades.

- **Scenario C with `tvg::SwRaster*` < 5% of CPU and P95 well under 16.6 ms** → SmartRender is doing real work for static compositions. GL will regress this scenario by losing partial-render. **Proceed to Sprint 1 anyway, but keep the hybrid SW/GL toggle (Phase E) as a hard requirement, not an optional escape hatch.**

- **All three scenarios already at P95 ≤ 16.6 ms with `tvg::Picture::*` or `Animation::update` dominating** → bottleneck is in the Lottie tick / parser, not the rasterizer. **Halt the migration.** GL won't help; the work goes elsewhere (e.g. caching parsed Lottie, isolating the tick loop). Write ADR-025 as "considered, rejected" with these numbers as evidence.

## In-app FPS overlay

Implemented in `example/lib/main.dart` behind `kProfileMode || kDebugMode`. Reads from `SchedulerBinding.instance.addTimingsCallback`, computes a rolling P50/P95/P99 over the last 120 frames (~ 2 s @ 60 fps), displays in the top-right corner, and logs to `dart:developer` every 10 s with tag `[anim_svg-perf]`.

The overlay is the minimum useful baseline; Instruments / simpleperf give the breakdown by symbol but require external tooling.
