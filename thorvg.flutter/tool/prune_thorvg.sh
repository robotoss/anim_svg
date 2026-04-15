#!/usr/bin/env bash
# Prune thorvg upstream tree to the subset the iOS build actually compiles.
# Idempotent: safe to re-run after an upstream sync.
set -euo pipefail
cd "$(dirname "$0")/.."
T=thorvg
rm -rf \
  "$T/test" "$T/tools" "$T/cross" "$T/.github" \
  "$T/src/bindings" "$T/src/savers" \
  "$T/src/renderer/gl_engine" "$T/src/renderer/wg_engine" \
  "$T/src/loaders/svg" "$T/src/loaders/ttf" "$T/src/loaders/webp" \
  "$T/src/loaders/external_jpg" "$T/src/loaders/external_png" "$T/src/loaders/external_webp" \
  "$T/src/loaders/lottie/jerryscript" \
  "$T"/{AUTHORS,CODE_OF_CONDUCT.md,CODEOWNERS,CONTRIBUTING.md,CONTRIBUTORS.md,README.md,LICENSE}
echo "Pruned: thorvg/ is now $(du -sh "$T" | cut -f1)"
