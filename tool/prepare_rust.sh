#!/usr/bin/env bash
# Called from ios/anim_svg.podspec `prepare_command` and android/build.gradle
# `preBuild`. Builds the native artifacts if they're missing, skips if
# they're present (respects a full clean to force rebuild).
#
# Invocation:
#   ./tool/prepare_rust.sh ios
#   ./tool/prepare_rust.sh android

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
    "$SCRIPT_DIR/build_rust_ios.sh"
    ;;
  android)
    JNI="$REPO_ROOT/android/src/main/jniLibs/arm64-v8a/libanim_svg_core.so"
    if [ -f "$JNI" ] && [ "${FORCE_RUST_REBUILD:-0}" != "1" ]; then
      echo "[prepare_rust] android artifacts already present (set FORCE_RUST_REBUILD=1 to rebuild)"
      exit 0
    fi
    "$SCRIPT_DIR/build_rust_android.sh"
    ;;
  *)
    echo "[prepare_rust] unknown target: $target" >&2
    exit 1
    ;;
esac
