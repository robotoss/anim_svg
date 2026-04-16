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
)

# Xcode's default ARCHS for iphonesimulator is `arm64 x86_64` even on Apple
# Silicon hosts (so Rosetta-only simulators still link). The xcframework
# install step rejects the whole framework if any listed arch is missing,
# so we always produce an x86_64 simulator slice and lipo it into the
# simulator archive. Set WITH_X86_SIM=0 to skip (arm64-only dev loop).
if [ "${WITH_X86_SIM:-1}" = "1" ]; then
  TARGETS+=(x86_64-apple-ios)
fi

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

if [ "${WITH_X86_SIM:-1}" = "1" ]; then
  SIM_X86="$CRATE_DIR/target/x86_64-apple-ios/$PROFILE/libanim_svg_core.a"
  SIM_COMBINED_DIR="$CRATE_DIR/target/ios-sim-universal/$PROFILE"
  SIM_COMBINED="$SIM_COMBINED_DIR/libanim_svg_core.a"
  mkdir -p "$SIM_COMBINED_DIR"
  echo "[build_rust_ios] combining simulator slices with lipo"
  lipo -create "$SIM_ARM" "$SIM_X86" -output "$SIM_COMBINED"
else
  SIM_COMBINED="$SIM_ARM"
fi

rm -rf "$XCF_PATH"
mkdir -p "$OUT_DIR"

echo "[build_rust_ios] assembling xcframework"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB"    -headers "$HEADERS_SRC" \
  -library "$SIM_COMBINED"  -headers "$HEADERS_SRC" \
  -output "$XCF_PATH"

echo "[build_rust_ios] done → $XCF_PATH"
