#!/usr/bin/env bash
# Driver for building native/anim_svg_core for the platforms this package
# targets. Invoke with no args to build for the current host (macOS builds
# iOS + Android; Linux builds Android only; Windows unsupported here).
#
# Pass a subset of {ios, android} to build selectively:
#   ./tool/build_rust.sh ios
#   ./tool/build_rust.sh android
#   ./tool/build_rust.sh ios android

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

args=("$@")
if [ ${#args[@]} -eq 0 ]; then
  case "$(uname -s)" in
    Darwin) args=(ios android) ;;
    Linux)  args=(android) ;;
    *)      echo "[build_rust] unsupported host OS: $(uname -s)" >&2; exit 1 ;;
  esac
fi

for target in "${args[@]}"; do
  case "$target" in
    ios)     "$SCRIPT_DIR/build_rust_ios.sh" ;;
    android) "$SCRIPT_DIR/build_rust_android.sh" ;;
    *)       echo "[build_rust] unknown target: $target" >&2; exit 1 ;;
  esac
done
