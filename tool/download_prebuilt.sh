#!/usr/bin/env bash
# Fetches prebuilt native artifacts from the project's GitHub Release
# (tag v<pubspec.version>) and extracts them into place. Called from
# tool/prepare_rust.sh before falling back to a local Rust build.
#
# Invocation:
#   ./tool/download_prebuilt.sh ios
#   ./tool/download_prebuilt.sh android
#
# Exit codes:
#   0 — artifact downloaded, verified, extracted
#   1 — skipped (ANIM_SVG_SKIP_DOWNLOAD=1) or any failure (caller should fall back)
#
# Environment:
#   ANIM_SVG_SKIP_DOWNLOAD=1  — skip download and return non-zero immediately
#   ANIM_SVG_RELEASE_BASE_URL — override for testing / mirrors
#                              (default: https://github.com/zoxo-outlook/anim_svg/releases/download)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

target="${1:-}"
if [ -z "$target" ]; then
  echo "[download_prebuilt] missing arg (ios|android)" >&2
  exit 1
fi

if [ "${ANIM_SVG_SKIP_DOWNLOAD:-0}" = "1" ]; then
  echo "[download_prebuilt] ANIM_SVG_SKIP_DOWNLOAD=1, skipping remote fetch"
  exit 1
fi

# Extract version from pubspec.yaml (first line starting with `version:`).
version="$(awk '/^version:/ {print $2; exit}' "$REPO_ROOT/pubspec.yaml")"
if [ -z "$version" ]; then
  echo "[download_prebuilt] could not read version from pubspec.yaml" >&2
  exit 1
fi

base_url="${ANIM_SVG_RELEASE_BASE_URL:-https://github.com/zoxo-outlook/anim_svg/releases/download}"
tag="v${version}"

case "$target" in
  ios)
    asset_name="anim_svg_core-${version}-ios.zip"
    dest_parent="$REPO_ROOT/ios/Frameworks"
    dest_final="$dest_parent/anim_svg_core.xcframework"
    ;;
  android)
    asset_name="anim_svg_core-${version}-android.tar.gz"
    dest_parent="$REPO_ROOT/android/src/main"
    dest_final="$dest_parent/jniLibs"
    ;;
  *)
    echo "[download_prebuilt] unknown target: $target" >&2
    exit 1
    ;;
esac

asset_url="${base_url}/${tag}/${asset_name}"
sha_url="${asset_url}.sha256"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "[download_prebuilt] fetching $asset_url"
if ! curl -fL --silent --show-error --retry 2 --connect-timeout 10 -o "$tmp_dir/$asset_name" "$asset_url"; then
  echo "[download_prebuilt] download failed; caller will fall back to local build" >&2
  exit 1
fi

echo "[download_prebuilt] fetching $sha_url"
if ! curl -fL --silent --show-error --retry 2 --connect-timeout 10 -o "$tmp_dir/$asset_name.sha256" "$sha_url"; then
  echo "[download_prebuilt] sha256 download failed; refusing to install unverified artifact" >&2
  exit 1
fi

expected_sha="$(awk '{print $1; exit}' "$tmp_dir/$asset_name.sha256")"
if command -v shasum >/dev/null 2>&1; then
  actual_sha="$(shasum -a 256 "$tmp_dir/$asset_name" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual_sha="$(sha256sum "$tmp_dir/$asset_name" | awk '{print $1}')"
else
  echo "[download_prebuilt] no shasum or sha256sum on PATH" >&2
  exit 1
fi

if [ "$expected_sha" != "$actual_sha" ]; then
  echo "[download_prebuilt] checksum mismatch (expected $expected_sha, got $actual_sha)" >&2
  exit 1
fi

mkdir -p "$dest_parent"
rm -rf "$dest_final"

case "$target" in
  ios)
    if ! unzip -q "$tmp_dir/$asset_name" -d "$dest_parent"; then
      echo "[download_prebuilt] unzip failed" >&2
      exit 1
    fi
    if [ ! -d "$dest_final" ]; then
      echo "[download_prebuilt] archive did not contain anim_svg_core.xcframework" >&2
      exit 1
    fi
    ;;
  android)
    mkdir -p "$dest_final"
    if ! tar -xzf "$tmp_dir/$asset_name" -C "$dest_final"; then
      echo "[download_prebuilt] tar extraction failed" >&2
      exit 1
    fi
    if [ ! -f "$dest_final/arm64-v8a/libanim_svg_core.so" ]; then
      echo "[download_prebuilt] archive missing arm64-v8a/libanim_svg_core.so" >&2
      exit 1
    fi
    ;;
esac

echo "[download_prebuilt] ${target} artifacts installed from ${tag}"
