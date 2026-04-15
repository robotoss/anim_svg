# Knowledge base

Links to things you actually need to keep at hand when working with this package.

## Specifications

- **Lottie 5.x JSON schema**: https://lottiefiles.github.io/lottie-docs/
  - Overview: https://lottiefiles.github.io/lottie-docs/specs/
  - Layers: https://lottiefiles.github.io/lottie-docs/layers/
  - Properties (animated/static, bezier handles): https://lottiefiles.github.io/lottie-docs/properties/
  - Keyframe interpolation (`i`/`o`/`h`): https://lottiefiles.github.io/lottie-docs/concepts/#bezier
- **SMIL 3.0 (W3C)**: https://www.w3.org/TR/SMIL3/
  - Animation module (`animate`, `animateTransform`, `keyTimes`, `keySplines`, `calcMode`): https://www.w3.org/TR/SMIL3/smil-animation.html
- **SVG 1.1 + SVG Animation**: https://www.w3.org/TR/SVG11/animate.html
- **CSS Animations Level 1**: https://www.w3.org/TR/css-animations-1/ —
  `@keyframes`, `animation-*` shorthand, per-keyframe
  `animation-timing-function`, fill-mode, direction.
- **CSS Motion Path Module Level 1**: https://www.w3.org/TR/motion-1/ —
  `offset-path`, `offset-distance`, `offset-rotate`.
- **SVG Filter Effects**: https://www.w3.org/TR/filter-effects-1/ —
  `feComponentTransfer`, `feFuncR/G/B`, `feColorMatrix`.

## Extending the converter (recipe for a new CSS property)

Template, verified on ADR-016…020. Runs without hard-coded ids.

1. **Parsing** (`lib/src/data/parsers/svg_css_parser.dart` or
   `svg_parser.dart`): read the new property from the
   @keyframes / inline-style declaration. Emit it either as an extension of
   `SvgAnimate`/`SvgAnimateTransform`, or as a new data-marker on the
   existing `SvgAnimate(attributeName='<property>')` entity.
2. **Domain** (`lib/src/domain/entities/`): if the semantics are not
   covered by existing entities — add a new one (immutable,
   sealed). Attach it to `SvgNode` via an optional field.
3. **Normalizer** (`lib/src/data/mappers/animation_normalizer.dart`):
   **always** propagate the new field into the rebuilds of `SvgGroup/SvgImage/
   SvgUse/SvgShape` — otherwise it will be lost after normalization
   (painful source of bugs).
4. **Resolver** (new module in `lib/src/data/mappers/`): if the
   property requires geometric context (motion-path length,
   brightness scale) — isolate it in a separate mapper step in
   `SvgToLottieMapper.map()`. Inputs/outputs are domain entities, so the
   module can be tested without Lottie.
5. **Serializer** (`lib/src/data/serializers/lottie_serializer.dart`):
   if a new Lottie effect/layer-type appears — add a case to
   `_effectMap`/`_layerMap`. Always use the official `mn`
   codes (`ADBE ...`) — any Lottie renderer looks at these.
6. **Export** (`lib/anim_svg.dart`): add `export` for new
   public entities if tests will reference them.
7. **Tests:** unit for the parser, unit for the resolver (if any),
   integration via `SvgToLottieMapper.map()`, serializer smoke
   (checks JSON structure).
8. **Docs:** ADR (context/decision/consequences), entry in
   `feature_map.md`, terms in `glossary.md`, README table.

## Tools

- **thorvg** (renderer): https://pub.dev/packages/thorvg · upstream: https://github.com/thorvg/thorvg
  - Supports both SVG and Lottie natively. We use only the Lottie path.
- **package:xml**: https://pub.dev/packages/xml — XML/SVG parser.
- **package:lottie** (alternative renderer, pure-Dart): https://pub.dev/packages/lottie —
  kept as a fallback option; not wired up in the MVP.
- **LottieFiles Preview**: https://lottiefiles.com/preview — drop in JSON, see the result.
- **LottieFiles Editor**: https://lottiefiles.com/editor — visual JSON debugging.

## References from other converters

- Bodymovin (AE → Lottie): https://github.com/airbnb/lottie-web/tree/master/player — canonical keyframes implementation.
- `svg2lottie` (WASM, proof-of-concept): https://github.com/fuse-compositor/svg2lottie — see their approaches to SMIL mapping.
- `lottie-android`: https://github.com/airbnb/lottie-android — reference Java renderer.

## Locally in this repo

- `example/assets/test_svg.svg` — production reference for the MVP.
- `test/fixtures/*.svg` — minimal isolated cases for unit tests.
- `~/.pub-cache/hosted/pub.dev/thorvg-1.0.0/lib/src/lottie.dart` — source of
  the public `Lottie` widget from `thorvg` (useful to read before editing
  `AnimSvgView`).

## FAQ (quick answers)

- **Why do we multiply scale by 100 but not rotate?** Lottie scale is in percent
  (100 = original), rotate is in degrees; SVG scale is a factor, SVG rotate is
  in degrees. Bottom line: we convert scale, leave rotate alone.
- **Why is `display` mapped to `ks.o` with hold?** Lottie has no discrete
  visibility property at the layer-transform level. Hold-keyframes on opacity
  give the same visual effect (0 ↔ 100 without interpolation).
- **Why are splines computed "per segment"?** SMIL `keySplines` describes
  the transition between two keyframes; Lottie stores `o` (out) on the outgoing one and `i`
  (in) on the incoming — both are taken from the same spline segment.
- **Why should pivot-rotate go through `ks.a`, not through a bake?**
  The chain `T(p)·R(θ)·T(-p)` is mathematically equivalent to "position on
  a circle + rotation". A bake gives a correct render, but the layer origin
  drags the content around the circle, which looks like "the icon is flying".
  `ks.a = p, ks.p = p` gives Lottie native "rotate around anchor" without
  drift. See ADR-015.
- **Why can't we drop static CSS tracks on an animated
  node?** `@keyframes m { 0% { transform: translate(200,300) rotate(0) }
  100% { translate(200,300) rotate(360) } }` — `translate` is constant,
  but carries the pivot. If the parser drops it, the mapper sees only
  `rotate(replace)` and rotates around (0,0). See ADR-014 Track A.
- **`atan2(b, a)` returns [-π, π].** If the animation spins 360° and the
  mapper samples only endpoints, decomposition returns the same angle →
  rotation collapses to static. The fast path via `ks.a` (ADR-015) works
  around this; fallback — subdivide grid at sweep >120° + unwrap (±360°
  offsets) for monotonicity.
