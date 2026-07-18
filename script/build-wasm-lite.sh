#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/SDK/Web/wasm}"
SOURCE="$ROOT/Sources/OrzAudioKitCXX"

if ! command -v emcc >/dev/null 2>&1; then
  echo "emcc is required (activate the Emscripten SDK first)" >&2
  exit 2
fi

mkdir -p "$OUT"
emcc \
  "$SOURCE/dispatch/audio_engine.c" \
  "$SOURCE/dispatch/orz_dispatch.c" \
  "$SOURCE/stub_decoders.c" \
  "$SOURCE/bp/bp_impl.c" \
  "$SOURCE/midi/midi_impl.c" \
  "$SOURCE/ym6/ym6_impl.c" \
  "$SOURCE/ym6/lhasa_adapter.c" \
  "$SOURCE/ym6/lhasa/lh5_decoder.c" \
  "$SOURCE/ym6/unlzh_ym.c" \
  -I"$SOURCE/include" -I"$SOURCE/dispatch" \
  -O3 --no-entry \
  -s WASM=1 -s MODULARIZE=1 -s EXPORT_ES6=1 \
  -s EXPORT_NAME="OrzAudioCoreModule" \
  -s ENVIRONMENT='web,worker,node' -s FILESYSTEM=0 \
  -s ALLOW_MEMORY_GROWTH=1 -s MALLOC=emmalloc \
  -s EXPORTED_FUNCTIONS='["_orz_abi_version","_orz_build_info","_orz_status_message","_orz_get_format_count","_orz_get_format_info","_orz_probe","_orz_decoder_create_memory","_orz_decoder_get_stream_info","_orz_decoder_render_f32","_orz_decoder_seek","_orz_decoder_select_subsong_v1","_orz_decoder_reset","_orz_decoder_cancel","_orz_decoder_destroy_v1","_malloc","_free"]' \
  -s EXPORTED_RUNTIME_METHODS='["UTF8ToString","stringToUTF8","lengthBytesUTF8"]' \
  -o "$OUT/orz_audio_builtin.js"

test -s "$OUT/orz_audio_builtin.js"
test -s "$OUT/orz_audio_builtin.wasm"
echo "$OUT"
