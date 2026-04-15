#!/usr/bin/env bash
# Build the native/anim_svg_core Rust crate for iOS as an xcframework.
#
# Outputs:
#   ios/Frameworks/anim_svg_core.xcframework
#   ios/Frameworks/anim_svg_core.xcframework/*/Headers/anim_svg_core.h
#
# Required toolchain:
#   - Rust stable
#   - rustup targets: aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios-sim
#   - Xcode command-line tools (lipo, xcodebuild)
#
# Intended to be invoked by tool/prepare_rust.sh or CI before `pod install`.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
CRATE_DIR="$REPO_ROOT/native/anim_svg_core"
OUT_DIR="$REPO_ROOT/ios/Frameworks"
XCF_PATH="$OUT_DIR/anim_svg_core.xcframework"
HEADERS_SRC="$CRATE_DIR/include"

TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios-sim
)

PROFILE="${PROFILE:-release}"
CARGO_PROFILE_FLAG="--release"
if [ "$PROFILE" = "debug" ]; then
  CARGO_PROFILE_FLAG=""
fi

echo "[build_rust_ios] ensuring rustup targets are installed"
for t in "${TARGETS[@]}"; do
  rustup target add "$t" >/dev/null
done

echo "[build_rust_ios] building ($PROFILE) for ${TARGETS[*]}"
cd "$CRATE_DIR"
for t in "${TARGETS[@]}"; do
  cargo build $CARGO_PROFILE_FLAG --target "$t"
done

DEVICE_LIB="$CRATE_DIR/target/aarch64-apple-ios/$PROFILE/libanim_svg_core.a"
SIM_ARM="$CRATE_DIR/target/aarch64-apple-ios-sim/$PROFILE/libanim_svg_core.a"
SIM_X86="$CRATE_DIR/target/x86_64-apple-ios-sim/$PROFILE/libanim_svg_core.a"

SIM_COMBINED_DIR="$CRATE_DIR/target/ios-sim-universal/$PROFILE"
SIM_COMBINED="$SIM_COMBINED_DIR/libanim_svg_core.a"
mkdir -p "$SIM_COMBINED_DIR"

echo "[build_rust_ios] combining simulator slices with lipo"
lipo -create "$SIM_ARM" "$SIM_X86" -output "$SIM_COMBINED"

rm -rf "$XCF_PATH"
mkdir -p "$OUT_DIR"

echo "[build_rust_ios] assembling xcframework"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB"    -headers "$HEADERS_SRC" \
  -library "$SIM_COMBINED"  -headers "$HEADERS_SRC" \
  -output "$XCF_PATH"

echo "[build_rust_ios] done → $XCF_PATH"
