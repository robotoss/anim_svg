#!/usr/bin/env bash
# Build the native/anim_svg_core Rust crate for Android ABIs and drop the
# resulting .so files into android/src/main/jniLibs/<abi>/.
#
# Required toolchain:
#   - Rust stable
#   - rustup targets: aarch64-linux-android, armv7-linux-androideabi,
#                     x86_64-linux-android, i686-linux-android
#   - cargo-ndk (`cargo install cargo-ndk`)
#   - Android NDK r25+ on PATH or ANDROID_NDK_HOME set
#
# Intended to be invoked by tool/prepare_rust.sh or Gradle preBuild.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
CRATE_DIR="$REPO_ROOT/native/anim_svg_core"
JNI_DIR="$REPO_ROOT/android/src/main/jniLibs"

PROFILE="${PROFILE:-release}"
CARGO_PROFILE_FLAG="--release"
if [ "$PROFILE" = "debug" ]; then
  CARGO_PROFILE_FLAG=""
fi

ABIS=(
  arm64-v8a
  armeabi-v7a
  x86_64
  x86
)

# Map Android ABI -> Rust triple (for documentation; cargo-ndk handles it).
RUST_TARGETS=(
  aarch64-linux-android
  armv7-linux-androideabi
  x86_64-linux-android
  i686-linux-android
)

echo "[build_rust_android] ensuring rustup targets are installed"
for t in "${RUST_TARGETS[@]}"; do
  rustup target add "$t" >/dev/null
done

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "[build_rust_android] ERROR: cargo-ndk not installed. Run: cargo install cargo-ndk" >&2
  exit 1
fi

echo "[build_rust_android] building ($PROFILE) for ${ABIS[*]}"
cd "$CRATE_DIR"

# cargo-ndk drops .so files into -o <dir>/<abi>/libanim_svg_core.so
mkdir -p "$JNI_DIR"
cargo ndk \
  -t arm64-v8a \
  -t armeabi-v7a \
  -t x86_64 \
  -t x86 \
  -o "$JNI_DIR" \
  build $CARGO_PROFILE_FLAG

echo "[build_rust_android] done → $JNI_DIR"
