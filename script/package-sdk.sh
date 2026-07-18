#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${1:-builtin-lite}"
OUT="${2:-$ROOT/.cmake-build/release}"
VERSION="$(node -p "require('$ROOT/decoder-manifest.json').sdkVersion")"
STAGE="$OUT/OrzAudioCore-$VERSION-$PRESET"

"$ROOT/script/build-sdk.sh" "$PRESET"
rm -rf "$STAGE"
mkdir -p "$STAGE/native" "$STAGE/metadata" "$STAGE/licenses"
cmake --install "$ROOT/.cmake-build/$PRESET" --prefix "$STAGE/native"
cp "$ROOT/decoder-manifest.json" "$STAGE/metadata/decoder-manifest.json"
cp "$ROOT/LICENSE" "$STAGE/licenses/OrzAudioCore-LICENSE"
cp "$ROOT/Sources/OrzAudioKitCXX/ym6/lhasa/COPYING.md" "$STAGE/licenses/lhasa-COPYING.md"
cp "$ROOT/Docs/orz-audio-core.md" "$STAGE/README.md"

node "$ROOT/script/generate-release-metadata.mjs" "$STAGE"
tar -C "$OUT" -czf "$STAGE.tar.gz" "$(basename "$STAGE")"
shasum -a 256 "$STAGE.tar.gz" > "$STAGE.tar.gz.sha256"
echo "$STAGE.tar.gz"
