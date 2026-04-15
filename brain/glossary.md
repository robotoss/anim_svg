# Glossary

If you encounter a term in the code and don't understand it — look here.

## SVG / SMIL

- **SMIL** (Synchronized Multimedia Integration Language) — a declarative
  animation language inside SVG. Tags `<animate>`, `<animateTransform>`,
  `<animateMotion>`, `<set>`.
- **attributeName** — which property `<animate>` animates (for example,
  `opacity`, `display`, `transform`).
- **values** — list of values separated by `;` for keyframes. The primary way
  to declare an animation in the MVP (alternatives `from/to/by` are not supported).
- **keyTimes** — normalized moments `[0..1]` for each value from
  `values`. Length must match `values`.
- **keySplines** — cubic-bezier `x1 y1 x2 y2` for each segment between
  adjacent keyframes. Used when `calcMode="spline"`.
- **calcMode** — interpolation mode: `linear` (default) · `spline` ·
  `discrete` (no interpolation, hold) · `paced` (proportional to segment length).
- **additive** — `replace` (default) replaces the previous value,
  `sum` is added to it. In SVG this allows chaining several
  `animateTransform` on one node (typical scale-around-point pattern).
- **use / defs** — `<defs>` stores reusable nodes by `id`,
  `<use xlink:href="#id">` inserts such a node into the tree. In Lottie
  there is no equivalent — we unfold them up front (flatten).

## Lottie

- **Root fields**: `v` (spec version), `fr` (frame rate), `ip` (in-point,
  first frame), `op` (out-point, last frame), `w`/`h` (canvas size),
  `assets[]`, `layers[]`.
- **Layer type `ty`**: `0` precomp, `1` solid, `2` image, `3` null, `4` shape,
  `5` text. We emit only `2` in the MVP.
- **`ks` (transform)** — block with `a` (anchor), `p` (position), `s` (scale,
  percentages), `r` (rotation, degrees), `o` (opacity, 0..100).
- **Property object**: `{"a":0, "k": <value>}` — static;
  `{"a":1, "k":[<keyframes>]}` — animated.
- **Keyframe**: `{"t": frame, "s": startValue, "i": {x,y}, "o": {x,y}, "h": 0|1}`.
  `i`/`o` — cubic bezier ease handles; `h:1` — hold interpolation.
- **Asset**: `{"id":..., "w":..., "h":..., "p": <path or dataURI>, "e": 0|1, "u": ""}`.
  `e:1` — embedded (data URI), `e:0` + `u` + `p` — external file.
- **refId** — layer reference to `asset.id`.

## ThorVG

- **Thorvg** — C++ vector renderer library (SVG/Lottie/TVG).
  In Flutter it is connected via FFI.
- **Lottie widget** — `package:thorvg` provides `Lottie.asset/memory/...`
  constructors and the `onLoaded(Thorvg engine)` callback for accessing the engine.

## Internal terms

- **UseFlattener** — pipeline step that expands `<use>` into an inline copy
  of the node from `<defs>`.
- **Feature map** — the "SVG feature → Lottie field → status" table in
  `brain/feature_map.md`. Source of truth for coverage.
- **Clean layers** — `domain` (entities, usecases) does not know about `data` or
  `presentation`; `data` does not know about `presentation`.
- **Pivot-pair pattern** — canonical AE/Figma export for "rotate/
  scale around a point": outer `<g transform="translate(p)
  rotate/scale(...)">` plus inner `<image transform="translate(-p)">`.
  The outer pre-translate and inner post-translate cancel each other
  when the animation is static; when animated, the effect is rotation/scaling
  around `p`. See ADR-015.
- **Anchor-pivot fast path** — `_buildAnchorPivotTransform`: the baker's
  fast path for chains where `mBefore/mGroupBase/mAfter` are pure
  translations. Maps the pivot to Lottie `ks.a` instead of baking the chain into
  per-keyframe TRS. Preserves animations "as is" and avoids
  atan2-wrap + orbital position drift. See ADR-015.
- **atan2-wrap** — the `decomposeTRS` trap: `math.atan2(b, a)` returns
  an angle in [-π, π]. If an animated rotation crosses ±180° and the mapper
  samples only endpoints, decomposition yields the same angle → `ks.r`
  collapses to static. Cured either by anchor-pivot (ADR-015) or
  by subdivide+unwrap in general-bake.
- **CSS pivot-pair (Track A)** — when parsing `@keyframes` you must not
  drop static transform tracks: `translate(p)` with identical
  keyframes carries pivot information. If you drop it, the downstream baker
  loses the pivot and rotates around (0,0). See ADR-014.
- **Primary animation** — in `_buildBakedTransform` the animation with the
  largest number of keyframes. Its sample points and bezier handles drive the output;
  the other animations are sampled at the same points. Relevant only for the
  general-bake fallback — the anchor-pivot fast path (ADR-015) is free of this.
- **Motion Path (CSS)** — `offset-path: path('M...')` + animation of
  `offset-distance: N%` in `@keyframes`. Defines the motion trajectory of a
  node along a curve. `offset-rotate: auto|reverse|Ndeg` adds
  automatic rotation along the tangent. Resolved in
  `MotionPathResolver` into a pair of translate+rotate tracks. See ADR-017.
- **offset-distance** — CSS property [0%, 100%], percentage of the length of
  `offset-path`. 0% = start of the curve, 100% = end. In `@keyframes` it is
  usually declared as linear 0→100 or with easing.
- **Null-layer (Lottie `ty:3`)** — a layer with no visual content,
  needed only as a transform (`ks`) carrier for `parent`-inheritance.
  Children with `parent = N` receive this layer's `ks` as a pre-transform.
  Used in ADR-018 for chains of animated `<g>`.
- **Lottie parenting** — the `parent: N` reference mechanism (where N is the `ind`
  of another layer) on a `LottieLayer`. The parent layer's transform is applied before
  the child's. Analogous to SVG nesting `<g transform="..."><child>`.
  Supported by thorvg; depth-cliff ~8 layers.
- **Equal-dur chain** — a chain of nested `<g>` elements where each
  animateTransform has a matching `dur · repeatCount` (tolerance 1e-3). Condition for
  parenting mode (ADR-018): a single timeline `t` across all levels.
- **Bezier tangent (B'(t))** — first derivative of a cubic Bezier:
  `B'(t) = 3(1−t)²(P₁−P₀) + 6(1−t)t(P₂−P₁) + 3t²(P₃−P₂)`. Direction of the
  tangent to the curve at point `t`. Used for `offset-rotate: auto`.
  For a degenerate cubic (straight `L` command, all control points
  on a line) it produces a zero vector — fallback to chord direction (p3 − p0).
- **Brightness effect (Lottie `ty:22`)** — `ADBE Brightness & Contrast 2`.
  The `brightness` channel is a signed offset in AE units; 0 = neutral.
  Empirical correspondence with RGB multiplier: `brightness = slope·100 − 100`.
  See ADR-020.
