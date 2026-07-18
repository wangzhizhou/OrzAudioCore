#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-}"

if [[ -z "$DEST" ]]; then
  echo "Usage: $0 <empty-destination>" >&2
  exit 2
fi
if [[ -e "$DEST" ]] && [[ -n "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Destination must be empty: $DEST" >&2
  exit 2
fi

mkdir -p \
  "$DEST/Sources/OrzAudioKit" \
  "$DEST/Libraries/OrzAudioKit" \
  "$DEST/SDK" \
  "$DEST/Tests" \
  "$DEST/Docs" \
  "$DEST/script" \
  "$DEST/cmake" \
  "$DEST/.github/workflows"

cp -R "$ROOT/Sources/OrzAudioKitCXX" "$DEST/Sources/"
cp "$ROOT/Sources/OrzAudioKit/AudioDecoder.swift" "$DEST/Sources/OrzAudioKit/"
cp "$ROOT/Sources/OrzAudioKit/DecoderManifest.generated.swift" "$DEST/Sources/OrzAudioKit/"
cp -R "$ROOT/Libraries/OrzAudioKit/thirdparty" "$DEST/Libraries/OrzAudioKit/"
cp -R "$ROOT/SDK/Web" "$DEST/SDK/"
cp -R "$ROOT/Tests/SDK" "$DEST/Tests/"
cp -R "$ROOT/cmake/." "$DEST/cmake/"

cp "$ROOT/CMakeLists.txt" "$ROOT/CMakePresets.json" "$ROOT/decoder-manifest.json" "$ROOT/LICENSE" "$DEST/"
cp "$ROOT/SDK/Standalone/Package.swift" "$DEST/Package.swift"
cp "$ROOT/SDK/Standalone/README.md" "$DEST/README.md"
cp "$ROOT/SDK/Standalone/.gitignore" "$DEST/.gitignore"
cp -R "$ROOT/SDK/Standalone/Tests/." "$DEST/Tests/"
cp "$ROOT/SDK/Standalone/.github/workflows/ci.yml" "$DEST/.github/workflows/ci.yml"
cp "$ROOT/SDK/Standalone/.github/workflows/release.yml" "$DEST/.github/workflows/release.yml"
cp "$ROOT/SDK/Standalone/.github/workflows/full.yml" "$DEST/.github/workflows/full.yml"
cp "$ROOT/Docs/orz-audio-core.md" "$ROOT/Docs/orz-audio-core-extraction.md" "$DEST/Docs/"

for script in \
  build-native-libs.sh build-sdk.sh build-wasm.sh build-wasm-lite.sh build-xcframework.sh \
  generate-decoder-manifest.mjs generate-release-metadata.mjs package-sdk.sh export-audio-core.sh; do
  cp "$ROOT/script/$script" "$DEST/script/$script"
done
chmod +x "$DEST/script/"*.sh

node "$DEST/script/generate-decoder-manifest.mjs"
node "$DEST/script/generate-decoder-manifest.mjs" --check
echo "$DEST"
