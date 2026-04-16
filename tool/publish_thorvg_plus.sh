#!/usr/bin/env bash
# Publish the vendored `thorvg_plus` package (source-built fork of thorvg).
#
# Why this script exists:
#   `dart pub publish` consults .pubignore files from the enclosing directory
#   tree, not just the current package. The anim_svg root .pubignore excludes
#   `thorvg.flutter/` so that anim_svg's own publish stays small. When run
#   from inside `thorvg.flutter/`, that same rule hides every file under the
#   child package — including its pubspec.yaml — and pub refuses to publish.
#
#   This script temporarily hides the outer .pubignore for the duration of
#   the child publish and always restores it, even on failure.
#
# Usage:
#   ./tool/publish_thorvg_plus.sh            # real publish (uses --force to
#                                              skip the interactive y/N prompt
#                                              which crashes on macOS with
#                                              "Missing extension byte" when
#                                              Stdin.readLineSync reads the
#                                              reply)
#   ./tool/publish_thorvg_plus.sh --dry-run  # validation only
#   ./tool/publish_thorvg_plus.sh --no-force # real publish with the
#                                              interactive prompt (will crash
#                                              on some macOS setups — see
#                                              https://github.com/dart-lang/pub/issues/4207)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
CHILD="$REPO_ROOT/thorvg.flutter"
OUTER_PUBIGNORE="$REPO_ROOT/.pubignore"
OUTER_PUBIGNORE_BACKUP="$REPO_ROOT/.pubignore.thorvg_plus_publish_bak"

if [ ! -d "$CHILD" ]; then
  echo "[publish_thorvg_plus] missing $CHILD" >&2
  exit 1
fi

restore() {
  if [ -f "$OUTER_PUBIGNORE_BACKUP" ]; then
    mv "$OUTER_PUBIGNORE_BACKUP" "$OUTER_PUBIGNORE"
    echo "[publish_thorvg_plus] restored outer .pubignore"
  fi
}
trap restore EXIT INT TERM

if [ -f "$OUTER_PUBIGNORE" ]; then
  mv "$OUTER_PUBIGNORE" "$OUTER_PUBIGNORE_BACKUP"
  echo "[publish_thorvg_plus] moved outer .pubignore aside"
fi

cd "$CHILD"
case "${1:-}" in
  --dry-run)
    flutter pub publish --dry-run
    ;;
  --no-force)
    flutter pub publish
    ;;
  "")
    flutter pub publish --force
    ;;
  *)
    echo "[publish_thorvg_plus] unknown arg: $1" >&2
    echo "usage: $0 [--dry-run|--no-force]" >&2
    exit 1
    ;;
esac
