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

## Baseline numbers (FILL IN AFTER RUN)

### iOS — iPhone Анна (2), iOS 26.3.1

| Scenario | P50 (ms) | P95 (ms) | P99 (ms) | Top-1 symbol | Top-2 symbol | Top-3 symbol | IOSurface count |
|---|---|---|---|---|---|---|---|
| A — single fullscreen | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| B — list of 24 | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| C — single small static | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

### Android — Pixel 6 emulator (or device, specify)

| Scenario | P50 (ms) | P95 (ms) | P99 (ms) | Top-1 symbol | Top-2 symbol | Top-3 symbol | Graphics PSS (KB) |
|---|---|---|---|---|---|---|---|
| A — single fullscreen | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| B — list of 24 | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| C — single small static | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## Decision gate (read after baseline is captured)

After Sprint 0 numbers are filled in, compare:

- **Scenarios A and B with `tvg::SwRaster*` or `__memcpy_aarch64` in top-3 + P95 above 16.6 ms** → bottleneck is CPU rasterization or the surface copy. **Proceed to Sprint 1.** This is the case GL will fix in spades.

- **Scenario C with `tvg::SwRaster*` < 5% of CPU and P95 well under 16.6 ms** → SmartRender is doing real work for static compositions. GL will regress this scenario by losing partial-render. **Proceed to Sprint 1 anyway, but keep the hybrid SW/GL toggle (Phase E) as a hard requirement, not an optional escape hatch.**

- **All three scenarios already at P95 ≤ 16.6 ms with `tvg::Picture::*` or `Animation::update` dominating** → bottleneck is in the Lottie tick / parser, not the rasterizer. **Halt the migration.** GL won't help; the work goes elsewhere (e.g. caching parsed Lottie, isolating the tick loop). Write ADR-025 as "considered, rejected" with these numbers as evidence.

## In-app FPS overlay

Implemented in `example/lib/main.dart` behind `kProfileMode || kDebugMode`. Reads from `SchedulerBinding.instance.addTimingsCallback`, computes a rolling P50/P95/P99 over the last 120 frames (~ 2 s @ 60 fps), displays in the top-right corner, and logs to `dart:developer` every 10 s with tag `[anim_svg-perf]`.

The overlay is the minimum useful baseline; Instruments / simpleperf give the breakdown by symbol but require external tooling.
