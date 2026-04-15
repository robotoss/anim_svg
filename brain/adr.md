# ADR — Architecture Decision Records

Each ADR is a short entry in the format: **context / decision / consequences**.
Add new decisions **at the end** of the file; do not rewrite old ones — only
mark them `SUPERSEDED` and link to the new ADR.

---

## ADR-001: thorvg as renderer, pure-Dart parser as a thin layer

**Context.** We need to render animated SVGs with SMIL in Flutter. Options:
(a) flutter_svg without animations, (b) a custom SVG core on Flutter canvas,
(c) thorvg directly with SVG, (d) thorvg with Lottie plus a custom SVG→Lottie
converter.

**Decision.** Option (d). Lottie is a mature format with full coverage of the
animations we need in thorvg; SMIL in thorvg does not work across all scenarios.
The `SVG → Lottie JSON` layer lets us swap the renderer in the future (thorvg ↔
the lottie package) without breaking the pipeline.

**Consequences.** + The plugin stays compatible with any Lottie renderer.
+ It tests cleanly, without a Flutter runtime. − We duplicate SMIL-parsing work
(thorvg in SVG mode handles some of it itself).

## ADR-002: Runtime conversion rather than a pre-build CLI

**Context.** SVG → Lottie can be done (i) offline via a CLI (commit the ready
JSON), (ii) at runtime inside the application.

**Decision.** Runtime. The user keeps the original SVG in assets and receives
Lottie dynamically. The parser core stays pure-Dart, so a CLI mode can be added
later (Sprint 3) without architectural changes.

**Consequences.** + One source of truth — the SVG file. + Easy to change the SVG
without rebuilding. − Parsing burns CPU on the first render; a cache will be
needed in Sprint 3.

## ADR-003: `package:xml` instead of a custom parser

**Context.** We can write a regex-based / handwritten parser, or use
`package:xml`.

**Decision.** `package:xml`. Pure-Dart, no Flutter, stable, covers namespaces
(`xlink:`).

**Consequences.** + Less code, fewer bugs. − An external dependency, but tiny
and long stable.

## ADR-004: `<use>` is expanded before mapping (UseFlattener)

**Context.** Lottie has no analogue of `<use>` — it has `refId` for assets, but
not for arbitrary subtrees. Options: (a) flatten before mapping, (b) emit a
Lottie precomp (`ty:0`) per defs node.

**Decision.** Flatten. Simpler, works for the SMIL case (transforms/animations
on `<use>` are applied on top), and does not lose properties.

**Consequences.** + Linear mapping with no dependency graph. − JSON grows when
`<use>` is reused many times. Acceptable for MVP; if it becomes a problem we
will replace it with a precomp in Sprint 3.

## ADR-005: `display` is mapped to opacity with hold keyframes

**Context.** SMIL can animate `display="none|inline"`, but the Lottie layer
transform cannot — it only has `ks.o`, which is numeric.

**Decision.** We map `<animate attributeName="display" values="none;inline;...">`
to `ks.o` hold keyframes: `none→0`, everything else→100, `h:1`.

**Consequences.** + Visually indistinguishable. − If the user's SVG animates
both `display` and `opacity` at the same time, one channel will override the
other. A rare case — documented in feature_map.

## ADR-006: `fr` is fixed at 60, `op` is computed from `maxDur`

**Context.** SMIL has no notion of frame rate, animations can be of different
lengths (`dur`), while Lottie has a single `fr` and `op` (last frame).

**Decision.** Always `fr=60`. `op = ceil(maxDur · fr)`, where `maxDur` is the
maximum `dur` among all `<animate*>` in the tree. This gives a seamless loop
with `repeat:true`.

**Consequences.** + Predictable, easy to write tests for. − Animations with
different `dur` will "collapse" to the maximum period (short loops repeat
several times inside a long op). For an MVP with a single reference this is
correct.

## ADR-007: WebP → PNG transcode on the fly

**Context.** The Flutter binary `thorvg 1.0` is built with the loaders
`lottie, png, jpg` (see `flutter_build.ios.sh`/`.android.sh` in the package).
`<image>` with MIME `image/webp` silently renders as empty pixels — on
lottiefiles.com the same JSON plays back correctly, so the format is valid; it
is the thorvg decoder that breaks. Options: (a) document the limitation and
throw `UnsupportedFeatureException`, (b) transcode WebP → PNG at the moment the
asset is mapped, (c) rebuild thorvg with a WebP loader (a separate fork).

**Decision.** Option (b). In `ImageAssetBuilder` → `RasterTranscoder` we decode
WebP via `package:image` and re-encode to PNG. PNG/JPEG pass through without
extra work. The user notices nothing.

**Consequences.** + Compatibility with real SMIL stickers from the
Telegram/Meta ecosystem, where WebP is the standard. + We do not touch the
native thorvg code. − +1 dependency (`image: ^4.2`). − CPU on the first
conversion (one-off, cache in Sprint 3). − PNG is ~2–3× heavier than WebP, the
JSON bloats; acceptable for an in-memory pipeline.

## ADR-008: Static transform composition via a 3×3 matrix

**Context.** Initially, static-transform folding was naive: translates were
summed, scales multiplied, rotations summed — independently. This broke nested
cases like `<g transform="translate(100,0)"><use transform="scale(2)"/></g>`,
where the correct result is scale(2) around the anchor and then translate(100),
but the folding produced translate + scale without accounting for their mutual
influence. Worse still — `<use transform="matrix(...)">` (15 instances in the
reference), which was mapped to `SvgTransformKind.matrix` and **silently
ignored** by the folder → the background image was not scaled, positions
"floated".

**Decision.** In `SvgToLottieMapper._composeTransforms` we build a full 2D
affine 3×3 matrix from an ordered list of `SvgStaticTransform`, multiplying
left to right (the SVG application order). Then we decompose it into
translate·rotate·scale — exactly what Lottie's `ks.{p, r, s}` encodes.
Matrix nodes (those that nonetheless reach the mapper) are included in the
product as-is. Additionally, `SvgTransformParser` decomposes
`matrix(a b c d e f)` into TRS at the input stage — so that downstream folding
and animations (which think in terms of translate/scale/rotate) see
comprehensible axes.

**Consequences.** + Correct for all SVGs without shear (99% of real exports
from Figma/Inkscape/Adobe Illustrator). + Matrices no longer "disappear" —
backgrounds no longer come out 50×50, positions are stable. − Shear
(`skewX/skewY` or a matrix with a non-zero shear component) is lost — we pick
the closest rotation. In MVP we throw `UnsupportedFeatureException` on
explicit `skewX/skewY`. − `atan2(b, a)` yields rotation in the range
[-π, π]; if an animation crosses ±180°, there can be a discontinuity — not
relevant in MVP, since we only decompose static transforms.

## ADR-009: SMIL "scale around pivot" → Lottie anchor

**Context.** SMIL exports (especially from After Effects / Animate CC)
express "animate scale/rotation around a point" as a chain of several
`<animateTransform>` on the same element:

```xml
<animateTransform additive="replace" type="translate" values="px,py;..."/>
<animateTransform additive="sum"     type="scale"     values="sx,sy;..."/>
<animateTransform additive="sum"     type="rotate"    values="deg,0,0;..."/>
<animateTransform additive="sum"     type="translate" values="-ax,-ay;..."/>
```

The effective per-frame transform is: `translate(p) · rotate(r) · scale(s) ·
translate(pivot)`. The previous `TransformMapper` simply overwrote
`ks.p`, `ks.s`, `ks.r` as it walked the list, and the second translate
animation **overwrote** the first — all shapes drifted to wrong absolute
coordinates (visible in test_svg_clean.svg: sprites and background were out of
place).

**Decision.** We recognise the canonical pattern and map:
- `additive="replace"` translate → `ks.p` (position).
- `additive="sum"` translate → `ks.a` (anchor), **with sign flip**.
- `additive="sum"|replace` scale → `ks.s` (in percent).
- `additive="sum"|replace` rotate → `ks.r` (in degrees).

The sign flip is derived from the formulas: SMIL gives
`output = p + R·S·(P + pivot)`, Lottie computes
`output = p + R·S·(P − a)`. For these to match — `a = −pivot`. Rotate-pivot
also works automatically, because Lottie rotates around the anchor.

**Consequences.** + Correct positions for all `<use>` + scale-around-point
animations without manually resampling keyframes. + Keyframe times of
different channels (ks.p vs ks.a) need not coincide — Lottie natively
supports independent per-property keyframes. − Non-standard combinations
(two `replace`-translates on the same node, a mixture of scale and skew,
etc.) throw `UnsupportedFeatureException` — not encountered yet; if they
appear we will decompose them into a full TRS bake.

## ADR-010: Baking parent `<g>` animation into child keyframes

**Context.** SMIL exports commonly have a pattern where a parent `<g>` is
animated and inside it several `<use>` nodes carry their own static
`transform` — background tiles, sprite grids, and the like. Example from
`test_svg.svg`:

```xml
<g transform="matrix(4.587 0 0 5.133 -313.65 332.8)">
  <animateTransform additive="replace" type="translate" values="..."/>
  <animateTransform additive="sum"     type="scale"     values="4.586,5.133;4.586,5.133"/>
  <use href="#f" transform="translate(56 -71)scale(.521)" />
  <use href="#f" transform="translate(116 -71)scale(.521)" />
  <use href="#f" transform="translate(56 -8)scale(.521)" />
  <use href="#f" transform="translate(116 -8)scale(.521)" />
</g>
```

In Lottie there is no group layer with an independent animation affecting
children (a precomp exists, but we use layer-per-image and a flat layers[]).
Previously, the mapper simply forwarded the parent's animations into the
`combinedAnims` list of every child, and TransformMapper applied the `replace`
translate directly to `ks.p` — losing the child's own `translate(56 -71)`. All
4 tiles collapsed to a single point.

**Decision.** In `_walk` we track a single "animated ancestor":
`staticsBefore` (everything above it), `_AnimatedAncestor(groupStatics, anims)`,
`staticsAfter` (everything below it down to the leaf). In `_buildBakedTransform`
we compute, for each leaf, the effective matrix at every keyframe point of the
"primary" animation (the one with the most keyframes — usually the
`replace`-translate):

```
M(t_i) = M_before · (base(t_i) · sum_1(t_i) · sum_2(t_i) · ...) · M_after
       where base = replace-anim(t_i) if present, else compose(group.staticTransforms)
```

We decompose every `M(t_i)` into TRS and emit on the layer an animated
`ks.p` + `ks.s` + `ks.r`. Bezier handles and calcMode are inherited from the
primary animation, so splines are preserved (for the canonical pattern
"translate with a spline + scale constant over 2 frames" this is correct — we
sample on the translate keyTimes, where scale is always the same).

**Consequences.** + Tiles take their positions; any scene with
parent-animated + child-static-transform renders correctly. +
Spline curves from the primary animation are preserved rather than collapsing
to linear. − Two different ancestors with animateTransform simultaneously on
one chain from the leaf → `UnsupportedFeatureException` (a rare case, we will
add recursive ancestor pumping in Sprint 2). − A leaf with its own
`<animateTransform>` under an animated ancestor also throws Unsupported —
combining two levels of animation requires either a precomp or a full bake
including leaf animations (backlog). − Secondary animations with mismatched
keyTimes/duration are sampled at primary points and can lose detail if the
secondary is also non-trivial; for the MVP coverage (secondary = constants over
2 keyframes) this is exact.

## ADR-011: Null-termination workaround for thorvg 1.0

**Context.** When loading a static Lottie (an SVG without SMIL, with animation
via CSS which we do not parse), the native `libthorvg.so` crashed with SIGSEGV
in `__strlen_aarch64`, called from `TvgLottieAnimation::load(char*, ...)`. The
reasons — two, independent, but both required for the crash:

1. `package:thorvg 1.0.0` FFI layer (`Uint8List.toPointer` in
   `thorvg/lib/src/thorvg.dart:168`) allocates exactly `length` bytes and
   copies the data without a trailing NUL byte. The native code
   (`src/tvgFlutterLottieAnimation.cpp:62`) calls
   `strlen(data)` on that pointer, assuming a C string. For
   small/compact JSONs, strlen reads past the end of the allocation.
2. Our mapper produced `op = ceil(maxDur · fr) = 0` for SVGs without
   `<animate*>` tags — `op == ip == 0`. The Lottie spec requires `op > ip`,
   and on a formally invalid document thorvg takes a broken code path where
   the out-of-bounds read fires.

**Decision.** Two local fixes:
- In `AnimSvgWidget._loadPipeline` we allocate `Uint8List(len + 1)` and
  copy UTF-8 into the first `len` bytes. `Uint8List` is zero-filled by
  default, so the last byte is `\0`. Overhead: +1 byte per JSON.
- In `SvgToLottieMapper` we clamp `outPointFrames` to a minimum of 1.0: even
  for a fully static document thorvg receives a valid single-frame Lottie.

**Consequences.** + `test_svg_3.svg` and any other static-only SVGs render
without crashing. + The workaround is independent of the `thorvg` version and
does not require forking the package. − We waste 1 extra byte per JSON
(negligible). − We need to file an issue upstream on `package:thorvg` so that
`toPointer` writes `\0`; once fixed, our code will keep working, but the
null terminator becomes redundant (not harmful).

## ADR-012: CSS `@keyframes` → SMIL equivalence at parse time

**Context.** `test_svg_3_clean.svg` (and a class of similar SVGs exported by
Figma / After Effects with CSS-only animation) declares animations via an
inline `<style><![CDATA[ ... ]]></style>` with `@keyframes` and the CSS
`animation` property. Our mapper understands only SMIL (`<animateTransform>`,
`<animate>`), and writing an alternative evaluator for CSS would duplicate
the keyframes / easing / additive-composition logic.

**Decision.** We translate CSS into its SMIL equivalent **at the parsing
stage**:

1. `SvgCssParser.parse(css)` collects all `@keyframes name { ... }` plus
   all `#id { animation: name dur timing iteration }` from each `<style>`.
2. Each keyframe is turned into a per-kind list (translate / scale /
   rotate); keyTimes are normalised to `[0..1]` with implicit 0%/100%
   inserted.
3. `cubic-bezier(x1,y1,x2,y2)` → `calcMode="spline"`, the same
   keySpline per segment.
4. If all values on a track are identical (static translate on an animated
   rotate), the track is skipped **without** flipping the `first` flag — that
   flag controls `additive="replace"` for the very first emitted animation,
   and skipping statics must not mutate the order.
5. `SvgParser` collects CSS from all `<style>` descendants (including those
   nested inside `<defs>`) and threads a `Map<elementId, List<anims>>`
   through `_parseNode` / `_parseGroup` /
   `_parseUse` / `_parseImage`; each node with an `id` appends the animations
   to its `animations` list before construction.

**Consequences.** + A single downstream pipeline — all animations go through
the same TransformMapper/OpacityMapper logic. + No CSS evaluator is needed at
runtime. + Compound / class selectors and unknown properties are logged and
skipped — `animation-delay`, `alternate`, `reverse` direction are not yet
supported (backlog). + The static-track skip is regression-checked by a test
in `svg_css_parser_test.dart`. − A single animation per node is the MVP
limit; multiple `animation: a, b;` → WARN (backlog).

## ADR-013: Drop the null terminator from Lottie JSON (supersedes part of ADR-011)

**Context.** ADR-011 added a trailing `\0` in the `Uint8List` passed to
`thorvg.Lottie.memory` so that native strlen() would not read past the end.
On Android, rendering `test_svg_*_clean.svg` caused all 4 tiles to fail with
`Unhandled Exception: FormatException: Unexpected character (at
character N)`, where N = `json_bytes`. Reason:
`package:thorvg/lib/src/lottie.dart:215` does
`final info = jsonDecode(data);` where `data` is the result of
`String.fromCharCodes(bytes)` in `parseMemory` (`utils.dart:70`). The NUL
byte after `}` becomes a literal `\u0000` in the string, and the Dart JSON
parser chokes on it. This extra read for `w/h` was not invoked on the old
code paths, but now blocks any render.

**Decision.** Removed the `+1` in the buffer allocation:
```dart
final bytes = Uint8List.fromList(utf8.encode(jsonStr));
```
The Op>=1 clamp from ADR-011 is kept — it alone is enough to keep native
thorvg out of the broken code path with the out-of-bounds strlen.

**Consequences.** + All 4 `*_clean.svg` files render on Android. + The buffer
is exactly the utf-8 length, compatible with the `jsonDecode` inside thorvg.
+ 51 tests green. − If we ever drop the op clamp and thorvg native does
strictly require `\0`, we will go back to a double buffer (copy JSON into a
`len+1`-byte Uint8List for FFI, pass a `len`-byte one for `jsonDecode`) or
fork `package:thorvg`.

## ADR-014: CSS parser — emit static transform channels to avoid losing the pivot

**Context.** `test_svg_3.svg` (a canonical AE/Figma "pivot-pair" export):

```xml
<g id="X_tr" transform="translate(200,300) rotate(0)">
  <image transform="translate(-200,-300)" .../>
</g>
<style>
  #X_tr { animation: m 8s linear infinite }
  @keyframes m {
    0%   { transform: translate(200px,300px) rotate(0deg) }
    100% { transform: translate(200px,300px) rotate(360deg) }
  }
</style>
```

The old `_compileAnimations` skipped any `type` track whose values were
identical across all keyframes (`values.toSet().length == 1`).
Only the `rotate` track with `additive="replace"` reached the mapper.
The downstream baker (ADR-010) wiped `mGroupBase = T(200,300)·R(0)` on the
first `replace`: the effective matrix became `R(θ)·T(-200,-300)`, and the
icon rotated around (0,0) rather than the pivot (200,300).

Additionally the parser had hard crashes / silent errors:
- `rotate()` with no arguments → `RangeError` on `args[0]`.
- `rotate(1turn)` → 1° (the suffix was stripped along with `grad`/`rad`).
- `matrix()`, `translate3d()`, `rotateX/Y/Z`, `skewX/Y` — unsupported and
  broke the whole rule.
- `animation: a 1s, b 2s` (multiple animations) — the tokenizer split on
  whitespace and lost the whole chain.
- `animation-name: ...` / `animation-duration: ...` in long form — ignored.
- Compound selectors `#a, #b { ... }` — treated as a single "#a, #b"
  selector.
- `steps(n)` / `step-start` / `step-end` — silently fell back to linear.
- `transform: none|initial|inherit` — the regex did not match → empty
  keyframe.

**Decision.** Two independent edits in `svg_css_parser.dart`:

- **Track A** (emit statics). `_compileAnimations` builds a per-kind list of
  PendingTracks without skipping statics. If **at least one** track varies,
  we emit them all in order: the first with `additive="replace"`, the rest
  with `additive="sum"`. The static `translate(200,300)` is preserved as a
  `replace` track with two identical keyframes and prevents the baker from
  losing the pivot.
- **Track B** (robustness, no-crash):
  1. `_parseCssAngle` recognises `deg` (default), `rad` (×180/π),
     `turn` (×360), `grad` (×0.9); applied to `rotate`/`rotate3d`/
     `skewX`/`skewY` args.
  2. Bounds-checked helper `_arg(list, i, fallback)` — any access to the
     function arguments goes through it.
  3. `matrix(a b c d e f)` → `SvgTransformKind.matrix` with 6 args.
     `TransformMapper` then WARN-skips matrix animations; acceptable.
  4. `translate3d(x,y,z)` / `scale3d(x,y,z)` → drop z.
     `rotateZ` — alias for `rotate`. `rotateX/Y`, `rotate3d` — WARN+skip.
  5. `transform: none|initial|inherit` → an empty list (identity).
  6. `_splitTopLevelCommas` — depth-aware splitting for `animation: a, b`
     and for compound selectors `#a, #b`.
  7. Long-form `animation-name/-duration/-timing-function/-iteration-count`
     are synthesised into shorthand if `animation:` itself is absent.
  8. `_timingToCalcMode` recognises `steps(n[,jump])` / `step-start` /
     `step-end` → `SvgAnimationCalcMode.discrete`.

**Consequences.** + `test_svg_3.svg` parses with two tracks on `_tr`:
constant-translate (replace) + rotate 0→360 (sum) — the pivot survives. +
Alternative CSS exports (with long form, `turn`/`rad`, compound selectors,
multi-animation, steps timing) also parse rather than crash. +
An unknown case at worst yields an identity frame plus a WARN — it never
throws. − Spline interpolation across `steps()` is not emulated exactly —
discrete steps only between the given keyframes. − `matrix()` tracks are
skipped by the mapper; TRS decomposition per keyframe is on the backlog.

## ADR-015: Pivot → Lottie `ks.a` (anchor) for pure translation chains

**Context.** ADR-010 baked the entire animated chain
`M_before · M_group · anim(t) · M_after` into TRS per keyframe. For the
pivot pattern (ADR-014, test_svg_3) the effective matrix is
`T(200,300)·R(θ)·T(-200,-300)`. `decomposeTRS` yields a mathematically correct
result: `ks.p` is animated along a circle around the pivot, `ks.r` is
animated as θ. The render is visually correct, **but** there are two
problems:

1. **atan2 wrap.** Decomposition via `atan2(b, a) * 180/π` returns
   [-180°, 180°]. At `t=0°` and `t=360°` the matrix is identical, so the
   extracted `rot=0°` at both endpoints. Since `primary.keyframes.keyTimes = [0,1]`
   (2 samples), `_collapseScalar` collapses `ks.r` into static(0). The icon
   does not rotate at all. First fix: subdivide (when sweep >120° on a segment)
   + unwrap (±360° offsets for monotonicity) — it worked, but created
   spurious keyframes and linearised the splines.
2. **Visual "drift".** Even with correct `ks.r`, `ks.p`
   is animated along a circle. The layer content, stored in SVG-native
   coordinates, rotates around its own origin, and the origin is dragged
   along the circle around the pivot. Mathematically exact; perceived as
   "the icon flies across the canvas".

**Decision.** We detect the structural pattern: if all three static
components of the chain (`mBefore`, `mGroupBase`, `mAfter`) are pure
translations and the animations are standard kinds (replace-translate,
sum-rotate, sum-scale), we take the fast path in `_buildAnchorPivotTransform`:

An algebraic identity (true for any `R(t)`, `S(t)`):
```
T(b) · T(p) · R(t)·S(t) · T(q) · local
   = (b + p) + R(t)·S(t)·(local − anchor)
         where position = b + p, anchor = −q
```

In Lottie this is exactly the layer formula — `position + R·S·(local − anchor)`.
We map:
- `ks.a` = `−mAfter.translation` (the child's T(-pivot) → anchor = pivot).
- `ks.p` = `mBefore.translation + replace-translate` (animated if present,
  otherwise `+ mGroupBase.translation`).
- `ks.r` = animated sum-rotate (no subdivide/unwrap).
- `ks.s` = animated sum-scale.

The layer content stays in SVG-native coordinates — Lottie itself computes
`local − anchor`, and the T(-pivot) from the SVG child is absorbed by that
subtraction. Rotation around the anchor → the icon rotates in place.

Subdivide + unwrap (the first fix) remain in the general-bake fallback as a
safety net for chains with rotation/scale/skew/matrix in the statics, where
the anchor pattern does not apply.

**Consequences.** + test_svg_3: `ks.a=(200,300)`, `ks.p=(200,300)`
(constant), `ks.r=0→360°` (animated) — two keyframes, no subdivide,
no loss of splines. The icon rotates in place, as in the source. +
The identity works for **any** `R(t), S(t)`, including a 5-stop scale
pulse and 8-segment rotations — it does not depend on the sweep magnitude or
the number of keyframes. + The "before Track A fix" variant is also rescued:
even if the parser forgot the replace-translate, `mGroupBase.translation`
is pulled into `ks.p`, and visually we still get rotate-in-place. −
Chains with rotate/scale in `staticsBefore/After/groupStatics` fall back
to general-bake — a rare case in AE/Figma, but possible. − Unsupported
additive patterns (two replace-translates, or a mix like sum-translate +
sum-scale) also go to general-bake, so as not to duplicate the anchor logic
of ADR-009 (SMIL pivot chain).

## ADR-016: Per-keyframe `animation-timing-function` in CSS

**Context.** CSS Animations Level 1 allows specifying
`animation-timing-function` both **inside** `@keyframes` — on each stop
individually — and in the `animation:` shorthand. The per-keyframe value
overrides the shorthand and sets the easing **from that stop to the next**.
Before ADR-016 the parser read only the shorthand → every segment got the
same `cubic-bezier`; AE/Rive/Adobe Animate exports, where each stop carries
its own `ease`, degraded to an averaged curve.

**Decision.** `_parseKeyframeBlock` additionally extracts the
`animation-timing-function` declaration inside each `_CssKeyframe` and parses
it via the existing `_timingToSpline` (for `cubic-bezier`, `ease*`, `linear`)
and `_timingToCalcMode` (for `step-*`, `steps()`). In `_compileAnimations`
a `perSegmentSplines` list of length `keyTimes.length - 1` is built: element
`i` = outgoing easing of keyframe `i`; fallback is the shorthand spline. If
at least one segment is non-linear → `calcMode = spline`; step-* → `discrete`
with a hold-handle at that index. `KeySplineMapper` already supported
per-segment splines — no change was needed.

**Consequences.** + test_svg_2: 27 sprites get the correct
curves. + Backward compat: SVGs without per-kf TF inherit the shorthand. −
A keyframe with `steps(N)` in the middle of a spline track makes the channel
mixed-discrete; we emit `discrete` for the whole channel and hold only at
that index — a rare case.

## ADR-017: CSS Motion Path (`offset-path`/`offset-distance`/`offset-rotate`)

**Context.** Modern exports (Adobe Animate, Rive) use
CSS Motion Path Module Level 1: `offset-path: path('M...')` in a node's
inline style, `@keyframes` animates `offset-distance: N%`,
`offset-rotate: auto|reverse|Ndeg` controls the orientation along the
tangent. In Lottie there is no motion path at the layer-transform level;
thorvg does not emulate CSS offset.

**Decision.** Parser-then-resolver. The CSS parser emits
`SvgAnimate(attributeName='offset-distance')` as a data marker (without
geometry); the SVG parser attaches `SvgMotionPath` to the node from the
inline style. `MotionPathResolver` runs in `SvgToLottieMapper.map()`
after normalise, before flatten: it finds `offset-distance` on a node with
`motionPath`, parses the `d` via the existing `SvgPathDataParser`, builds a
cumulative length table (32 subdivisions per cubic), samples `(x, y)` per
keyframe and the tangent via `B'(t)`. The output is a pair of
`SvgAnimateTransform`: translate (`replace`) + optional rotate
(`sum`, if `offset-rotate=auto`). Splines/holds are preserved.

**Consequences.** + `MotionPathResolver` is modular, with 5 unit tests. +
`TransformMapper` works unchanged. + Later it can be reused for
SMIL `<animateMotion>`. − 32 subdivisions ≈ <0.5px error on typical
export paths; very long curves may require adaptive flattening. −
Straight `L` commands are parsed as a degenerate cubic with
zero tangents; for `offset-rotate=auto` we fall back on the chord
direction (p3 − p0).

## ADR-018: Nested animated groups — hybrid parenting + bake

**Context.** Exporters often nest three animated `<g>` elements on a
sprite: `#_N_to` (translate) → `#_N_tr` (rotate) → `#_N_ts` (scale).
Before ADR-018 `_walk` skipped inner animations with a WARN. A pure bake
works only for an ancestor↔leaf pair. Lottie has a native
`parent` mechanism (a reference to the `ind` of a layer whose `ks` is
inherited as a pre-transform); thorvg supports it.

**Decision.** `NestedAnimationClassifier` determines the mode:
- **Parenting mode** (preferred): if all `dur · repeatCount`
  values match (tolerance 1e-3) — each animated `<g>` is emitted as a
  `LottieNullLayer` (`ty:3`) with its own `ks`; the leaf gets
  `parent = index of the nullLayer`. Depth guard: >6 → fall back to bake.
- **Bake mode**: mismatched dur and a single animated ancestor — the
  existing `_buildBakedTransform`.
- **WARN+skip**: incompatible durs across two+ levels — a documented
  limitation.

**Consequences.** + test_svg_2: 18 sprites come alive with correct
nesting. + Parenting does not break the anchor-pivot fast path (ADR-015):
it is applied at the leaf level after parenting. + Debug-friendly JSON:
null layers named `_N_to`, `_N_tr`. − thorvg parent-depth
performance cliff ≥8; depth limit 6. − Cyclical parent excluded
by construction.

## ADR-019: CSS animation options — delay / direction / fill-mode

**Context.** The `animation:` shorthand contains more than `name dur
timing iter`. Before ADR-019 the parser silently ignored `animation-delay`,
`animation-direction` (reverse / alternate / alternate-reverse),
`animation-fill-mode` (forwards / backwards / both). Delay-staggered
sprites started synchronously; reverse/alternate did not work.

**Decision.**
- **Delay:** `_AnimationShorthand.delaySeconds` — the second
  duration-like token in the shorthand. Mapping: shift `t` of all keyframes
  by `delay · fr`; `op` is extended to `delay + dur`.
- **Direction:** `SvgAnimationDirection` enum. `reverse` —
  invert `keyTimes` (`1 − t`) and `values`. `alternate` — double
  the cycle: [forward, reverse] in a single keyframe array of length
  `2·dur` (works correctly only with `repeatIndefinite`).
- **Fill-mode:** `SvgAnimationFillMode` enum. `forwards` — Lottie
  naturally holds the last keyframe; `backwards` — hold keyframe
  at `t=0` with the value `values[0]`.

**Consequences.** + Pulsation/stagger effects in test_svg_2
are synchronised. − `alternate` with a finite count introduces drift (a rare
case). − `fill-mode=both` is equivalent to `forwards` — thorvg does not
distinguish pre/post phases.

## ADR-020: `feComponentTransfer` → Lottie Brightness & Contrast

**Context.** SVG `feComponentTransfer` with children `feFuncR/G/B
type="linear" slope="N"` — the standard path for "color pulse"
(brightness ripple). Before ADR-020 the parser emitted WARN + drop. Lottie
has a `Brightness & Contrast` effect (`ty:22`, `mn:'ADBE Brightness
& Contrast 2'`); thorvg supports it. Per-channel linear slope Lottie
**does not have** — it would require `Tritone`/ColorMatrix, which
thorvg renders inaccurately.

**Decision.** A pragmatic fallback:
- `_parseComponentTransfer` reads the three `feFunc*` and their nested
  `<animate attributeName="slope">`.
- `_buildBrightnessEffect` chooses a representative (R, or the first
  animated one) and maps: `brightness = slope · 100 − 100`. So
  `slope=1` → brightness=0 (neutral), `slope=1.5` → 50, `slope=0.5`
  → −50. The formula is empirical: AE brightness [-150, 150] ≈ RGB
  multiplier [−0.5, 2.5].
- Independent RGB channels → WARN + mean slope (an MVP compromise).
- Identity (`slope=1` without animation) → the effect is not emitted.

**Consequences.** + test_svg_2 brightness-pulse is visible. + The effect
is serialised to the standard `ty:22` → any Lottie renderer will read it. −
Inaccurate channel-shift reproduction: a red pulse on a grey background
yields brightness instead of tint. For a strict RGB-gain emulation a
`ColorMatrix` effect is needed — backlog.

## ADR-021. Diagonal-matrix fast path in `_Mat.decomposeTRS`

**Context.** `_Mat.decomposeTRS` for the matrix `[[-1,0],[0,1]]` (a pure
horizontal flip, `scale(-1, 1)`) returned `sx=1`, `sy=-1`, `rot=180°`
— mathematically correct (`M = R(180) · S(1,-1)`), but when Lottie
applies rotation around the layer anchor rather than the SVG origin, the
visible flip happens vertically instead of horizontally. The user
sees "img3 duplicated vertically".

**Decision.** If `b ≈ 0 && c ≈ 0` (pure scale + translate, no shear
and no rotation), return `sx=a, sy=d, rot=0` without applying the det flag.
This covers all AE/Figma/Adobe Animate exports where `scale(-N, M)`
appears without an accompanying rotation. The general path (`atan2(b, a)` +
`sy = −sy` when `det < 0`) is preserved for shear/rotate combinations.

**Criterion.** Diagonal matrices are trivially tested by
`b.abs() < 1e-9 && c.abs() < 1e-9`. Any real shear or rotate
breaks the condition and routes to the general path.

**Consequences.** + Mirror idioms render correctly (img3 in
test_svg_2). + The regression on test_svg_3 (pivot-rotate) is unaffected —
pivot rotate goes through `_buildAnchorPivotTransform`. − None: the fast
path does not compete with the general one, it just eliminates the noisy
180° rotation on trivial inputs.

**Seam-closing bias (added in Sprint 3.1 after device smoke).**
After bug 1 was fixed, mirrored copies of img3 in test_svg_2 stood
mathematically correctly next to each other, but between them a visible
transparent strip of up to 2 px remained — an artifact of sub-pixel
rounding of the edges in thorvg with negative scale. In the fast path we
added an inward shift of 2 units along each of the negative axes (`a<0 ⇒ tx -= 2`,
`d<0 ⇒ ty -= 2`). This overlaps the seam between the mirror and its pair
by 2 px, guaranteeing a seamless render for a typical AE export
(scale(±N, M) around a shared pivot). A standalone `scale(-N)` without a pair
is offset by 2 px from the SVG-exact position — unnoticeable at sticker
sizes (viewport 200+ px). An alternative — detecting sibling pairs
before emission — is too expensive; the heuristic is simpler and covers all
real exports.

## ADR-022. CSS `transform-origin` → pre/post translate wrap

**Context.** In test_svg_2 there is `<g style="transform-origin:
289px 399px;" transform="matrix(...)"/>`. CSS semantics: the matrix
is applied in a coordinate system whose origin is `(ox, oy)`, which is
algebraically equivalent to `T(ox, oy) · M · T(-ox, -oy)`. Before Sprint 3.1
the parser ignored the attribute entirely — rotations and scales were
applied around `(0, 0)`, which gave a visible offset of ~ox/oy units.

**Decision.** At the parser stage we read `transform-origin` from the inline
style. With a non-empty list of static transforms we wrap it in a pair of
`translate(ox, oy)` before and `translate(-ox, -oy)` after. `Npx` and
unitless (treated as `px`) are supported; `%` and keywords (`center`/`left`/
`right`/`top`/`bottom`) are logged + skipped (they require the node's bbox,
which is unknown at the parser level — backlog Sprint 4).

**Criterion.** Origin `(0, 0)` does not wrap — `T(0) · M · T(0) = M`.
In the absence of any static transforms the wrap is skipped (origin
without a transform — the identity case).

**Consequences.** + Matrix rotations with a transform-origin render
at the correct position (BUY FEATURE END in test_svg_2). − Wrap only
for the static pipeline; an animated `transform-origin` (allowed by CSS)
is not supported — backlog. − `%` and keywords are WARN+skip for now;
AE/Figma exports always write in px.

## ADR-023. `feColorMatrix saturate` → Lottie `ty:19` Hue/Saturation

**Context.** A SMIL sticker from test_svg_2 applies `<feColorMatrix
type="saturate" values="1" → 1.4 → 1">` for a saturation pulse.
Lottie has no native per-channel ColorMatrix effect, but
supports the AE Hue/Saturation effect (`ty:19`, mn `ADBE HUE
SATURATION`) with a Master Saturation channel in AE units [-100, 100].
Before Sprint 3.1 the primitive was WARN+skip dropped, while brightness from
`feComponentTransfer` was applied → the composite looked desaturated
and over-exposed.

**Decision.** In `_resolveEffects` the case `SvgFilterColorMatrix` with
`kind == saturate` emits `LottieHueSaturationEffect` with
`masterSaturation = (values - 1) * 100` (s=1 → 0 neutral,
s=2 → +100 boost, s=0 → -100 greyscale). An `<animate
attributeName="values">` animation → an animated `LottieScalarProp` via
`_mapScalarAnim(scale: 100)` + `_shiftScalar(-100)`. The serializer
emits five channels: Channel Control=0 (Master), Master Hue=0,
Master Saturation=<prop>, Master Lightness=0, Colorize=off.

**Criterion.** AE units on Hue/Saturation scale linearly:
+100 ≈ roughly double the saturation. thorvg/lottie-web
render this effect natively (`ty:19` is in the Lottie spec).
Other `feColorMatrix` kinds (`matrix`, `hueRotate`, `luminanceToAlpha`)
remain WARN+skip — backlog.

**Consequences.** + test_svg_2 colours are close to the source. + Two effects
(saturation + brightness) can coexist on the same layer. − Linear
SVG saturate and AE Master Saturation are not an exact mathematical
match; at extreme values (s > 3) the visual difference is noticeable.
− `feColorMatrix type="matrix"` with an arbitrary 4×5 matrix is
still not supported.
