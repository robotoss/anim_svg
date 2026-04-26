# brain.md — Active Mission: thorvg render-engine jank

> Cross-refs: [brain/adr.md](brain/adr.md), [brain/feature_map.md](brain/feature_map.md), [brain/knowledge.md](brain/knowledge.md), [brain/glossary.md](brain/glossary.md)
> Last updated: 2026-04-26
> Status: 🟢 Implemented (pending runtime verification) — Phase 2 native + Dart code merged; Android APK builds with all 10 JNI symbols exported; awaiting `flutter run --profile` on real target
> Out of scope (parked): Android fatal crash

---

## 0. Mission

**Goal:** eliminate UI jank caused by the thorvg_plus render engine when many `AnimSvgView` instances are visible simultaneously.

**Confirmed bottleneck (from source audit):**
- thorvg uses `SwCanvas` (software CPU rasterizer) with `EngineOption::None`.
- `canvas->draw(true) + sync()` runs synchronously on the UI isolate every vsync.
- `tvg.Lottie.memory(...)` is implemented as `CustomPaint` + `ui.Image`, NOT `Texture`, NOT `PlatformView`.
- N animations × 60 fps × 3 ops (raster + decodeImageFromPixels + setState) saturates the main thread.
- No GPU acceleration in the current path.

**Definition of Done:**
- [ ] Sustained 60 FPS while scrolling 50 visible `AnimSvgView` in profile mode (UI thread P95 < 16 ms).
- [ ] Same visual output as today (≥ 99% SSIM on golden frames).
- [ ] Off-screen animations consume 0 CPU.
- [ ] No memory growth over a 10-minute soak.
- [ ] ADR entry written in `brain/adr.md`.

---

## 1. Footnotes (invariants we must preserve)

- **FFI memory rule**: native pointers from thorvg are valid only between `tvg.render()` and the next `tvg.update()`. Do not retain them across async boundaries — copy if needed.
- **NUL-termination**: Lottie JSON bytes passed to thorvg must NOT have a trailing NUL — see ADR-013.
- **WebP**: thorvg cannot decode WebP `<image>`; current path uses `package:image` transcoding (CPU, ADR-007). Account for this in memory budgets.
- **thorvg_plus**: vendored fork at `/thorvg.flutter/`, source-built per platform via `prepare_command`. Don't switch back to upstream.
- **Public API stability**: downstream apps depend on `AnimSvgView.{asset,string,network}`. Any rendering refactor MUST preserve this signature.
- **No background isolate exists** for the render path — addressing this is the work of Phase 2.

---

## 2. Diagnosis status

### Hypotheses (validated against trace `dart_devtools_2026-04-26_10_54_43.622.json`, 244 frames, profile mode, emulator-5554)

| #  | Hypothesis                                                         | Status      | Evidence |
|----|--------------------------------------------------------------------|-------------|----------|
| H1 | Per-frame `SwCanvas::draw` on the UI isolate is the bottleneck     | ✅ CONFIRMED | UI build phase median **141 ms**, P95 **180 ms**, max **200 ms**, **238 / 244 frames janky** (build > 16.67 ms). Raster median 2.3 ms, P95 4.5 ms — GPU side is fine. |
| H2 | Per-frame texture decode/upload adds cost                          | ✅ CONFIRMED | `1508 DecompressTexture` + `1534 UploadTextureToPrivate` events — ~7.6 per frame, matching 8 visible animations. Runs on `ConcurrentWorkerWake` (off UI), but drives churn. |
| H3 | Off-screen animations keep ticking                                 | ✅ Logical (no in-trace counter) | No public `pause()` API; no `VisibilityDetector` wired. List has 8 items, scroll keeps them mounted. |
| H4 | RepaintBoundary helps but doesn't fix raster cost                  | ✅ Indirectly confirmed | Raster thread P95 = 4.5 ms (within budget). Problem is upstream in BUILD/UI phase. |
| H5 | Stagger mount only helps cold-start, not steady-state scroll       | ✅ Confirmed | `startDelay: 10ms + index` (current production usage) is even smaller than the 100ms hack — confirms author already knew it was useless. |

### Trace summary

- **244 Flutter frames captured.** Total elapsed > 16.67ms in **244 / 244** (100% of frames jank).
- **UI/Build thread saturated** at ~141 ms median per frame → effective FPS ≈ 7.
- **Raster (GPU) thread idle** — the bottleneck is NOT the GPU.
- 8 visible `AnimSvgView` items at width:300 × height:300 (DPR ~2.5 on emulator → ~750×750 px software-rasterized per frame per animation = ~4.5 MPix/frame × 8 anims × 60 attempted fps = 2.16 GPix/sec on CPU — physically impossible on UI isolate).

### Diagnostic conclusions

1. **Phase 1 (visibility pause) alone will NOT fix this scenario** — all 8 items are visible simultaneously; pausing off-screen doesn't reduce on-screen cost.
2. **Phase 2 (Texture widget + native producer thread) is mandatory** — only way to free the UI isolate.
3. Optional secondary: clamp `tvg.resize()` to max 1× DPR (or explicit cap) — currently uses `1.0 + (DPR - 1) * 0.75`, which on emulator with DPR=2.5 yields 2.125. Halving the rasterized buffer area is a free 4× win.

---

## 3. Plan

### Phase 0 — Confirm bottleneck (current sprint)
Validate H1+H2 with a real Timeline before committing to Phase 2 cost.

### Phase 1+2 (merged) — Texture widget + native producer thread (main fix)
Phase 1 (visibility pause) was merged into Phase 2: the new MethodChannel-based controller exposes `play()/pause()` natively, so the visibility-pause work belongs on top of the new API rather than the legacy ticker.

Move `tvg.render()` off the UI isolate. Replace `CustomPaint` with `Texture(textureId)`.
- **Android**: JNI bridge → `HandlerThread` per texture → `SurfaceTextureEntry` + `Surface.lockHardwareCanvas`.
- **iOS**: ObjC++ bridge → `dispatch_queue` per texture → `FlutterTexture` + `CVPixelBuffer` pool.
- **Dart**: `Texture` widget + `MethodChannel`-backed `ThorvgController`.
- Old direct-FFI `Thorvg` class kept (deprecated) for backward compatibility.

### Phase 3 — thorvg SW speedups ✅
Internal SW backend wins applied (no GL vendoring needed):
- [x] `THORVG_NEON_VECTOR_SUPPORT` for arm64 / armeabi-v7a (CMake-gated; iOS guarded by `__aarch64__` / `__ARM_NEON`)
- [x] `Initializer::init(4)` — thorvg's TaskScheduler with 4 workers, parallel scanline rasterization. Side benefit: `ScopedLock`s become real mutexes (defence in depth for decision #5).
- [x] `EngineOption::SmartRender` + `THORVG_PARTIAL_RENDER_SUPPORT` — partial-redraw for static-heavy compositions.

### Phase 3.5 — thorvg GL backend (deferred)
The vendored fork ships only `sw_engine/`; `gl_engine/` sources from upstream would need to be added. Would also require an EGL context per surface on Android and a shared Metal-bridged GL context on iOS. Revisit only if Phase 3 SW speedups don't reach the visual smoothness target.

### Phase 4 — Validation & ship
Benchmark, soak test, ADR, CHANGELOG, version bump.

---

## 4. Sprint checklist (live)

### Sprint A — Diagnosis
- [x] Real list code received (2026-04-26)
- [x] Timeline trace received (2026-04-26 — `dart_devtools_2026-04-26_10_54_43.622.json`)
- [x] Hypotheses H1–H5 marked
- [x] Decision: **proceed with Phase 1 + Phase 2 in parallel.** Phase 1 alone insufficient.

### Sprint B — Visibility pause (merged into Sprint E)
Subsumed by the new `ThorvgController.pause()`/`resume()` API. `VisibilityDetector` wiring lives in `anim_svg/lib/src/presentation/anim_svg_widget.dart` and is added at the end.

### Sprint C — Native producer thread (Phase 2, Android) ✅
- [x] `android/src/main/cpp/jni_bridge.cpp` — JNI wrappers + composite `nativeRenderToSurface` (frame → update → render → ANativeWindow blit)
- [x] `android/CMakeLists.txt` — compile JNI bridge, link `android` library
- [x] `android/build.gradle` — added `kotlin-android` plugin + sourceSets
- [x] `android/src/main/kotlin/.../ThorvgPlusPlugin.kt` — FlutterPlugin + MethodChannel `thorvg_plus/texture` + texture registry
- [x] `android/src/main/kotlin/.../ThorvgTexture.kt` — `HandlerThread` per texture, `SurfaceTextureEntry`, drift-free `postAtTime` pacing, `lastFrameRendered` coalescing
- [x] Native handle ownership lives on Kotlin side (no more Dart `Pointer<FlutterLottieAnimation>` for the new path)
- [x] `flutter build apk --debug --target-platform=android-x64` succeeds; all 10 `Java_com_robotoss_thorvg_1plus_ThorvgTexture_*` symbols exported in `libthorvg.so`

### Sprint D — Native producer thread (Phase 2, iOS) ✅ (code-only)
- [x] `ios/Classes/ThorvgBridge.h` + `ThorvgBridge.mm` — ObjC++ wrapper over existing C++ API; SIMD swizzle (`vImagePermuteChannels_ARGB8888`) from thorvg ABGR → CVPixelBuffer BGRA
- [x] `ios/Classes/ThorvgPlusPlugin.swift` — FlutterPlugin + MethodCallHandler mirror of Android
- [x] `ios/Classes/ThorvgTexture.swift` — `FlutterTexture`, `CVPixelBufferPool` (3-deep), `DispatchSourceTimer` (16 ms), Metal-compatible IOSurface attrs
- [x] `ios/thorvg_plus.podspec` — `Classes/**/*.{m,mm,h,swift}` glob, Accelerate framework, `Classes/ThorvgBridge.h` exposed via `public_header_files`
- [ ] iOS build verification still pending (requires Mac/Xcode pod install run)

### Sprint E — Dart integration ✅
- [x] `lib/src/thorvg_controller.dart` — `MethodChannel`-backed controller; `create/play/pause/seek/resize/dispose`; explicit dispose on widget unmount
- [x] `lib/src/lottie.dart` — refactor to `Texture(textureId)`; `_loadGen` race-guard for hot reload + size changes; DPR-aware sizing
- [x] `lib/thorvg.dart` — exports `ThorvgController` alongside `Lottie`
- [x] `pubspec.yaml` — `pluginClass: ThorvgPlusPlugin` for both platforms (alongside `ffiPlugin: true` for legacy `Thorvg` class)
- [x] `flutter analyze` clean (only 3 pre-existing info lints)
- [ ] `lib/src/thorvg.dart` legacy `Thorvg` class — leave intact for now; mark `@Deprecated` after runtime validation
- [ ] `anim_svg/lib/src/presentation/anim_svg_widget.dart` `VisibilityDetector` wiring — deferred until runtime verification proves the new pipeline is the right baseline

### Sprint F — GL backend probe (Phase 3, optional)
- [ ] Check `thorvg.flutter` CMake for GL flag
- [ ] If present: `GlCanvas::gen` swap
- [ ] EGL/Metal context binding

### Sprint G — Validation & ship (Phase 4)
- [ ] Benchmark report (before/after) committed to `brain/`
- [ ] SSIM visual diff ≥ 99%
- [ ] Soak test 10 min — stable memory
- [ ] CHANGELOG, version bump
- [ ] ADR-XXX in `brain/adr.md`
- [ ] Feature flag flipped to default

---

## 5. Decision log

| # | Date       | Decision                                                                                      | Reasoning                                                                                  | Refs |
|---|------------|-----------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|------|
| 1 | 2026-04-26 | Park Android crash investigation                                                              | User explicit redirect; jank is higher value right now                                     | §0   |
| 2 | 2026-04-26 | Pursue Texture widget + native thread (Approach B), not full PlatformView                     | Hybrid Composition cost on Android, lose Dart-side API surface with full PlatformView      | §3 Phase 2 |
| 3 | 2026-04-26 | Phase 2 is mandatory; Phase 1 alone won't fix the scrolling-list jank                          | Trace shows median UI build = 141ms with 8 items all visible. Visibility-pause only saves off-screen CPU. | §2 |
| 4 | 2026-04-26 | Add a DPR-clamp investigation as secondary win                                                 | Current `1.0 + (DPR-1)*0.75` doubles buffer size on high-DPR; clamping to 1.0× saves 4× raster cost for free | §2 conclusion 3 |
| 5 | 2026-04-26 | **Single shared render thread**, not per-texture. Lose intra-screen parallelism, keep correctness. | First runtime test crashed with SIGSEGV in `canvas->update()` (tid `thorvg-tex-1`). Root cause: thorvg's `ScopedLock` is a no-op when `TaskScheduler::threads() == 0` (`tvgLock.h:38-42`), so the global `LoaderMgr::_activeLoaders` is unprotected. 8 concurrent `nativeLoad` calls raced. Path 3 (`Initializer::init(N)`) would spawn extra worker threads system-wide. Single shared thread keeps the UI isolate freed (the actual goal) while thorvg sees only one caller. | (this file §6) |
| 6 | 2026-04-26 | Enable **NEON SIMD** + **`Initializer::init(4)`** + **`EngineOption::SmartRender`** to lift the shared-thread rendering throughput. | After fix #5 the UI thread became free (DevTools confirms — no more jank in build phase) but visual playback remained choppy: one CPU thread can't keep up with 8 SwCanvas rasterizations at 60 FPS. Available wins inside the existing fork: (a) NEON intrinsics (`THORVG_NEON_VECTOR_SUPPORT`) — gated by ABI in CMake, ~2-3× faster scanline blits; (b) `Initializer::init(4)` — thorvg now uses its task scheduler to parallelize a single `canvas->draw` across 4 workers (and turns the previously no-op `ScopedLock`s into real mutexes — defense in depth for #5); (c) `EngineOption::SmartRender` (`THORVG_PARTIAL_RENDER_SUPPORT`) — partial redraw of dirty regions, big win for slot-machine logos with mostly-static backgrounds. None require vendoring new sources. GL backend deferred (gl_engine sources are not in this fork; would need upstream vendoring + EGL/Metal context plumbing). | (this file §3 Phase 3) |

---

## 6. Rejected approaches

| #  | Idea                                                                | Why rejected                                                                                              |
|----|---------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| R1 | Full `AndroidView`/`UiKitView` PlatformView                          | Hybrid Composition penalty on Android; complex lifecycle; loses Dart play/pause control                   |
| R2 | Move FFI convert to Isolate                                          | Not the bottleneck per user — converter doesn't freeze, render does                                       |
| R3 | Replace thorvg with native Lottie                                    | Loses thorvg's SVG-specific support; large API change; pulls additional dependency                        |
| R4 | Per-texture native render thread (was first attempt)                 | Crashed: thorvg's `ScopedLock` is a no-op with `threads()==0`, so global `LoaderMgr` raced when 8 textures loaded in parallel. See decision #5. |
| R5 | `Initializer::init(N)` to enable thorvg's internal locks             | Spawns N extra worker threads inside thorvg, multiplying total threads by N+1 textures; cure worse than disease for jank-sensitive workloads. |

---

## 7. Open questions

- [ ] Where is the real production list code — in this repo or downstream?
- [x] Refactor `thorvg.flutter` in place (vendored), or fork to a new namespace? → **in place**
- [ ] Acceptable to bump min Flutter version if Texture API requires it?
- [x] Is iOS rendering currently OK, or also janky? → **also janky, same problem** (per user)
- [ ] Are there downstream apps already on v0.0.3 that we'd break?

### Buffer-shape optimization (deferred)

User-observed: `height` in `AnimSvgView` strongly affects perf, `width` does not.
Confirmed in [src/tvgFlutterLottieAnimation.cpp:143-156](thorvg.flutter/src/tvgFlutterLottieAnimation.cpp): for portrait Lottie sources (`psize[1] > psize[0]`), `scale = height / psize[1]`. Width only contributes lateral padding via `shiftX`. Effective rasterized area is `(psize[0]/psize[1]) × h²`.

Optimization candidate: clamp the native buffer size to the actual picture render bounds rather than the requested widget size, removing wasted padding (~33% memory + memcpy savings on a 300×300 widget hosting a 400×600 lottie). Not done now because it changes the buffer-vs-widget contract — the Texture widget would need to be wrapped in an `AspectRatio`/`FittedBox` to preserve the same composition.
