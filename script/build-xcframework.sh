#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.cmake-build/xcframework}"

"$ROOT/script/build-sdk.sh" ios-device-lite
"$ROOT/script/build-sdk.sh" ios-simulator-lite
rm -rf "$OUT/OrzAudioCore.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library "$ROOT/.cmake-build/ios-device-lite/libOrzAudioCore.a" -headers "$ROOT/Sources/OrzAudioKitCXX/include" \
  -library "$ROOT/.cmake-build/ios-simulator-lite/libOrzAudioCore.a" -headers "$ROOT/Sources/OrzAudioKitCXX/include" \
  -output "$OUT/OrzAudioCore.xcframework"
echo "$OUT/OrzAudioCore.xcframework"
