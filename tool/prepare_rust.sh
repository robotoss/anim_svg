#!/usr/bin/env bash
# Called from ios/anim_svg.podspec `prepare_command` and android/build.gradle
# `preBuild`. Ensures native artifacts are in place, in this order:
#   1. If artifacts already present and FORCE_RUST_REBUILD != 1 — no-op.
#   2. Try to download prebuilt artifacts from the GitHub Release for the
#      current pubspec version.
#   3. Fall back to a local Rust build (requires toolchain).
#
# Invocation:
#   ./tool/prepare_rust.sh ios
#   ./tool/prepare_rust.sh android
#
# Environment:
#   FORCE_RUST_REBUILD=1      — ignore cached artifacts and re-run from scratch
#   ANIM_SVG_SKIP_DOWNLOAD=1  — skip the GH Release fetch, go straight to build

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

target="${1:-}"
if [ -z "$target" ]; then
  echo "[prepare_rust] missing arg (ios|android)" >&2
  exit 1
fi

case "$target" in
  ios)
    XCF="$REPO_ROOT/ios/Frameworks/anim_svg_core.xcframework"
    if [ -d "$XCF" ] && [ "${FORCE_RUST_REBUILD:-0}" != "1" ]; then
      echo "[prepare_rust] ios artifacts already present at $XCF (set FORCE_RUST_REBUILD=1 to rebuild)"
      exit 0
    fi
    if [ "${FORCE_RUST_REBUILD:-0}" != "1" ] && "$SCRIPT_DIR/download_prebuilt.sh" ios; then
      exit 0
    fi
    echo "[prepare_rust] building ios artifacts from source"
    "$SCRIPT_DIR/build_rust_ios.sh"
    ;;
  android)
    JNI="$REPO_ROOT/android/src/main/jniLibs/arm64-v8a/libanim_svg_core.so"
    if [ -f "$JNI" ] && [ "${FORCE_RUST_REBUILD:-0}" != "1" ]; then
      echo "[prepare_rust] android artifacts already present (set FORCE_RUST_REBUILD=1 to rebuild)"
      exit 0
    fi
    if [ "${FORCE_RUST_REBUILD:-0}" != "1" ] && "$SCRIPT_DIR/download_prebuilt.sh" android; then
      exit 0
    fi
    echo "[prepare_rust] building android artifacts from source"
    "$SCRIPT_DIR/build_rust_android.sh"
    ;;
  *)
    echo "[prepare_rust] unknown target: $target" >&2
    exit 1
    ;;
esac
