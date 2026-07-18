#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-builtin-lite}"

case "$PROFILE" in
  builtin-lite|macos-arm64|macos-x86_64|linux-x86_64|ios-device-lite|ios-simulator-lite|wasm-full|wasm-lite) ;;
  *) echo "Unknown SDK preset: $PROFILE" >&2; exit 2 ;;
esac

node "$ROOT/script/generate-decoder-manifest.mjs" --check
cmake --preset "$PROFILE" -S "$ROOT"
cmake --build --preset "$PROFILE"
if [[ "$PROFILE" != wasm-* && "$PROFILE" != ios-* ]]; then
  ctest --test-dir "$ROOT/.cmake-build/$PROFILE" --output-on-failure
fi
