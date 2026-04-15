# Feature map — SVG → Lottie

Statuses: ✅ done · 🟡 partial · ⛔ not-supported (in current sprint) · 🔜 planned

## Document structure

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `<svg width h viewBox>` | `w`, `h`, `ip=0`, `op=ceil(maxDur·fr)` | ✅ | `fr` fixed = 60 |
| `<defs>` + `<use xlink:href="#id">` | flatten before mapping | ✅ | `UseFlattener` — recursion limit 32 |
| `<g>` (no display) | unwrapped, transforms folded into children | ✅ | |
| `<g display="none">` without animation | skip | ✅ | Does not land in Lottie layers |
| `<g display="none">` with `<animate display>` | hold-keyframes on `ks.o` | ✅ | See DisplayMapper |
| `<image xlink:href="data:image/png\|jpeg;base64,...">` | `assets[].p` (data URI) + `ty:2` layer | ✅ | `e:1`, base64 pass-through |
| `<image xlink:href="data:image/webp;base64,...">` | transcoded → PNG asset | ✅ | thorvg cannot handle WebP — decode+encodePng via `package:image` (see ADR-007) |
| `<image xlink:href="https://...">` | — | 🔜 Sprint 3 | |

## Transforms

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `transform="translate(x y)"` (static) | ks.p.k = [x, y] | ✅ | |
| `transform="scale(s)"` / `scale(sx sy)` (static) | ks.s.k = [s·100, s·100] | ✅ | Lottie uses percentages |
| `transform="rotate(deg)"` (static) | ks.r.k = deg | ✅ | |
| `transform="rotate(deg cx cy)"` (static) | deg only | 🟡 | pivot not carried over (MVP) |
| `transform="matrix(a b c d e f)"` (static) | translate+rotate+scale | ✅ | TRS decomposition (SVG exporters do not produce shear — decomposition is exact). For diagonal matrices (`b=c=0`) fast path preserves the sign of `sx/sy` without rotation — see ADR-021 |
| `transform="scale(-N, M)"` / `scale(N, -M)` (static or in a matrix with `b=c=0`) | ks.s with a negative component, ks.r=0 | ✅ Sprint 3.1 | Mirror around layer anchor; no spurious `rot=180°`. See ADR-021 |
| CSS `transform-origin: Xpx Ypx` (inline style) | wraps static transform into `T(ox,oy) · M · T(-ox,-oy)` | ✅ Sprint 3.1 | `px` + unitless supported; `%` / keywords (`center`/`left`/...) → WARN + skip (requires bbox). See ADR-022 |
| `transform="skewX/skewY"` | — | ⛔ | Sprint 2 |

## Animations

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `<animate attributeName="opacity">` | ks.o anim (0..100) | ✅ | |
| `<animate attributeName="display">` | ks.o hold-anim | ✅ | `none→0`, otherwise→100 |
| `<animateTransform type="translate">` | ks.p anim | ✅ | |
| `<animateTransform type="scale">` | ks.s anim (×100) | ✅ | Uniform scale "0.5" → [50,50] |
| `<animateTransform type="rotate">` | ks.r anim | ✅ | deg only, no pivot |
| `<animateTransform type="skewX/Y">` | — | ⛔ | |
| `<animateTransform type="matrix">` | — | ⛔ | |
| `<animateMotion>` | motion path | 🔜 Sprint 2 | |
| `<set>` | instant keyframe | 🔜 Sprint 2 | |
| `from="..." to="..."` (sugar) | requires `values=` | ⛔ | MVP requires `values` |

## Timing and interpolation

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `dur="1.833s"` / `"500ms"` | `t = keyTime · dur · fr` | ✅ | Supports `s`, `ms`, no suffix (seconds) |
| `repeatCount="indefinite"` | loop via `Lottie(repeat: true)` | ✅ | `op` computed from the first period |
| `keyTimes="0;0.5;1"` | `t` of each keyframe | ✅ | Required when `values` > 2 |
| `keySplines="x1 y1 x2 y2;..."` | `i:{x:[x2],y:[y2]}, o:{x:[x1],y:[y1]}` | ✅ | Per-segment |
| `calcMode="linear"` (default) | linear `i=(0,0)/o=(1,1)` | ✅ | |
| `calcMode="spline"` | bezier handles | ✅ | |
| `calcMode="discrete"` | `h:1` on all keyframes | ✅ | |
| `calcMode="paced"` | — | ⛔ | Sprint 2 (compute by segment length) |
| `additive="sum"` translate (pivot) + `additive="replace"` translate | ks.p (replace) + ks.a = −(sum) | ✅ | Canonical SMIL idiom "scale around pivot" — see ADR-009 |
| `additive="sum"` scale / rotate (single) | ks.s / ks.r directly | ✅ | |
| Two `replace` translates / two scales / two rotates on the same node | — | ⛔ | UnsupportedFeatureException — rare case |
| Nested `<g transform>`/`<use transform>` (mixed translate+scale+rotate) | composition of 3×3 matrix → decomposition into TRS | ✅ | Correct for SVG without shear; see SvgToLottieMapper._composeTransforms |
| Animated `<g>` with static `<use>` children (tiles, grids) | bake parent animation into `ks.{p,s,r}` of each leaf per-keyframe | ✅ | Sample points/splines taken from parent's primary animation; see ADR-010 |
| Pivoted rotate/scale (AE/Figma "pivot-pair": outer `T(p)` + inner `T(-p)`) | `ks.a = p`, `ks.p = p`, `ks.r/s` animated natively | ✅ | Fast path in `_buildAnchorPivotTransform` for pure-translation chains. Algebraic identity without bake/subdivide. See ADR-015 |
| Pivoted rotate with sweep >120° on a segment (general-bake fallback) | subdivide grid + angle unwrap | ✅ | Safety net for when fast path does not apply (say `staticsBefore` contains rotate) — otherwise `atan2` collapses `ks.r` to 0 |
| `<title>`, `<desc>`, `<metadata>`, `<clipPath>`, `<mask>`, `<pattern>`, `<marker>`, `<symbol>` | silently skipped | 🟡 | Decorative/metadata are not carried over; `<clipPath>` / `<mask>` are visually lost, but nodes still render |
| SVG-compact numeric notation (`1.01-2-3` = `1.01 -2 -3`, `1.2e-3-4.5`) in `transform` | tokenized correctly | ✅ | SVG minifiers strip spaces around signs, see SvgTransformParser._tokenizeNumbers |
| Animated `<g>` with a child that also has `<animateTransform>` | — | ⛔ | UnsupportedFeatureException — two-level bake, Sprint 2 backlog |
| Two different `<g>` elements with `<animateTransform>` on the same chain to a leaf | — | ⛔ | UnsupportedFeatureException — rare case |
| SVG without `<animate*>` (pure static) | static Lottie with `op=1` | ✅ | `op` clamped to 1 frame so thorvg does not degrade — see ADR-011 |
| `<style>` with `@keyframes name { ... }` + `animation: name dur timing iter;` | translated into `SvgAnimateTransform` at parse stage | ✅ | translate / scale / rotate / matrix / skewX/Y + `cubic-bezier` → `calcMode="spline"`. `animation-delay`, `alternate` — backlog. See ADR-012 / ADR-014 |
| CSS multiple animations (`animation: a 1s, b 2s`) | each compiles into its own `SvgAnimateTransform` | ✅ | Depth-aware split on top-level commas. See ADR-014 |
| CSS long-form (`animation-name/-duration/-timing-function/-iteration-count`) | shorthand synthesized at parse | ✅ | Fallback when `animation:` is absent |
| CSS compound selector (`#a, #b { ... }`) | both `id`s receive animations | ✅ | Depth-aware selector split |
| CSS angle units (`1turn`, `3.14rad`, `100grad`, `0.5deg`) | converted to degrees on rotate/skew | ✅ | turn×360 / rad×180/π / grad×0.9 |
| CSS `steps(n)` / `step-start` / `step-end` timing | `calcMode="discrete"` | ✅ | |
| CSS `rotate3d` / `rotateX` / `rotateY` / `translate3d` z / `scale3d` z | 2D part preserved, z dropped | 🟡 | `rotateX/Y`, `rotate3d` → WARN+skip; `translate3d/scale3d` → use only x,y |
| CSS `transform: none \| initial \| inherit` | identity (empty list) | ✅ | |
| CSS `matrix(a b c d e f)` inside `@keyframes` | emitted as `SvgTransformKind.matrix` | 🟡 | Mapper WARN-skips animated matrix (TRS decompose per-frame — backlog) |
| CSS crash-safety: `rotate()`, unknown functions, out-of-range args | identity + WARN, no throw | ✅ | bounds-checked helpers in `_parseCssTransform` |
| CSS `.class` / attribute / complex selectors | — | ⛔ | WARN + skip |

## Geometry

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `<path d="...">` | shape layer (`ty:4`) + `sh` | 🟢 | M/L/C/Q/Z/H/V/A (via `package:path_parsing`) |
| `<rect>` | `rc` | 🟢 | `rx/ry` → `r` (uniform radius) |
| `<circle>`, `<ellipse>` | `el` | 🟢 | |
| `<line>` | `sh` (2 vertices, open) | 🟢 | |
| `<polygon>`, `<polyline>` | `sh` | 🟢 | `closed=true` for polygon |
| `fill` (named / hex / `rgb()` / `none`) | `fl` with RGBA | 🟢 | |
| `fill="url(#gradient-id)"` → `<linearGradient>` / `<radialGradient>` | `gf` (`ty:"gf"`) | 🟢 | Static + animated `<stop offset>`. `gradientTransform` still ⛔ (WARN) |
| `stroke`, `stroke-width` | `st` | 🔜 Sprint 3 | MVP does not render stroke |
| `<filter><feGaussianBlur stdDeviation="N"/></filter>` | layer effect `ty:29`, radius ≈ N×2 | 🟢 | Animated `stdDeviation` supported. Inheritance of `filter=url(#f)` from a group down to leaves — via `inheritedFilterId` |
| `<feColorMatrix type="saturate" values="N">` + SMIL `<animate>` | layer effect `ty:19` (Hue/Saturation, `ADBE HUE SATURATION`) on the Master Saturation channel | ✅ Sprint 3.1 | `masterSat = (N − 1) · 100`. See ADR-023 |
| `<feColorMatrix type="matrix\|hueRotate\|luminanceToAlpha">` | — | ⛔ | WARN + skip (no Lottie equivalent) |
| `<feComponentTransfer>` with `feFuncR/G/B type="linear" slope="N"` | layer effect `ty:22` (Brightness & Contrast) | 🟡 | `brightness = slope·100 − 100`; per-channel independent slopes → WARN + mean fallback. See ADR-020 |
| SMIL `<animate attributeName="slope">` on `feFuncR/G/B` | animated `brightness` channel in `ty:22` | ✅ | Empirical scale to AE units. See ADR-020 |

## Motion Path (CSS Motion Path Module Level 1)

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `offset-path: path('M...')` on inline style | `SvgMotionPath` on the node + resolve to translate/rotate keyframes | ✅ | `MotionPathResolver`; see ADR-017 |
| `offset-distance: N%` in `@keyframes` | sampled `(x,y)` on curve-length → translate keyframes (replace) | ✅ | 32 subdivisions per cubic; <0.5px error |
| `offset-rotate: auto` | tangent angle via `B'(t)` → rotate keyframes (sum) | ✅ | Fallback to chord direction for degenerate cubics (straight `L`) |
| `offset-rotate: reverse` | tangent + 180° | ✅ | |
| `offset-rotate: Ndeg \| Nrad \| Nturn \| Ngrad` | constant rotate track | ✅ | |
| SMIL `<animateMotion>` | — | 🔜 Sprint 4 | Reuse `_PathSampler` |

## Nested animated groups

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| Chain of animated `<g>` with equal duration (Lottie-export pattern) | `LottieNullLayer` (`ty:3`) at each level + `parent` ref on leaf | ✅ | `NestedAnimationClassifier` in parenting mode; depth-guard 6. See ADR-018 |
| Chain with different durations (one animated ancestor) | bake into leaf via `_buildBakedTransform` | ✅ | Existing ADR-010 pipeline |
| Chain with two+ levels of different durations | — | ⛔ | WARN + skip inner levels (known limitation) |

## CSS animation options (Level 1 shorthand)

| SVG | Lottie | Status | Comment |
|---|---|---|---|
| `animation-delay: Ns` | shift `t` of all keyframes by `delay·fr`; `op = delay+dur` | ✅ | See ADR-019 |
| `animation-direction: reverse` | invert `keyTimes` / `values` | ✅ | |
| `animation-direction: alternate` (+ `indefinite`) | double cycle [forward, reverse] into one keyframe array | ✅ | Drift with finite count — documented |
| `animation-direction: alternate-reverse` | reverse + doubling | ✅ | |
| `animation-fill-mode: forwards` | Lottie layer naturally holds the last keyframe | ✅ | |
| `animation-fill-mode: backwards` | hold-keyframe at `t=0` with value `values[0]` | ✅ | |
| `animation-fill-mode: both` | equivalent to `forwards` in our model | 🟡 | thorvg does not distinguish pre/post-phase |
| `animation-timing-function` **inside `@keyframes`** (per-stop) | per-segment `BezierSpline[]` → `calcMode=spline` | ✅ | Fallback to shorthand. See ADR-016 |
| Mixed step-*/cubic-bezier in per-keyframe TF | channel becomes `discrete` with hold on step indices | 🟡 | Rare case, see ADR-016 |
