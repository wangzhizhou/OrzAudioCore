#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.wasm-build"
CACHE_DIR="$BUILD_DIR/cache"
SRC_DIR="$BUILD_DIR/src"
VENDOR_DIR="$ROOT/third_party/sources"

mkdir -p "$CACHE_DIR" "$SRC_DIR"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fetch() {
  local name="$1" url="$2" expected="$3"
  local archive="$CACHE_DIR/$name.tar.gz" destination="$SRC_DIR/$name"
  if [[ -f "$destination/.orz-source-sha256" ]] && [[ "$(cat "$destination/.orz-source-sha256")" == "$expected" ]]; then
    printf '[SOURCE] %s already verified\n' "$name"
    return
  fi
  if [[ ! -f "$archive" ]] || [[ "$(sha256 "$archive")" != "$expected" ]]; then
    printf '[SOURCE] Downloading %s\n' "$name"
    curl -fsSL --retry 4 --retry-all-errors "$url" -o "$archive"
  fi
  local actual
  actual="$(sha256 "$archive")"
  [[ "$actual" == "$expected" ]] || { printf 'SHA-256 mismatch for %s: %s\n' "$name" "$actual" >&2; exit 1; }
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination" --strip-components=1
  printf '%s\n' "$expected" > "$destination/.orz-source-sha256"
}

install_vendor() {
  local name="$1" archive_name="$2" expected="$3"
  local archive="$VENDOR_DIR/$archive_name" destination="$SRC_DIR/$name"
  [[ -f "$archive" ]] || { printf 'Missing vendored source: %s\n' "$archive" >&2; exit 1; }
  local actual
  actual="$(sha256 "$archive")"
  [[ "$actual" == "$expected" ]] || { printf 'SHA-256 mismatch for %s: %s\n' "$name" "$actual" >&2; exit 1; }
  if [[ -f "$destination/.orz-source-sha256" ]] && [[ "$(cat "$destination/.orz-source-sha256")" == "$expected" ]]; then
    printf '[SOURCE] %s already verified\n' "$name"
    return
  fi
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" --strip-components=1
  printf '%s\n' "$expected" > "$destination/.orz-source-sha256"
}

fetch libopenmpt \
  'https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.8.0+release.autotools.tar.gz' \
  '553ee9c63c4b3cbc9b664d5bc31d8bc4eeb345fad8809f03cbf93147a108ab32'
fetch game-music-emu \
  'https://github.com/libgme/game-music-emu/archive/refs/tags/0.6.3.tar.gz' \
  '4c5a7614acaea44e5cb1423817d2889deb82674ddbc4e3e1291614304b86fca0'
fetch libsidplayfp \
  'https://github.com/libsidplayfp/libsidplayfp/releases/download/v3.0.2/libsidplayfp-3.0.2.tar.gz' \
  'd67ab120ab8ca10657c0e33a7fc21638484e1af4037738c36faa66fb7747cac3'
fetch libbinio \
  'https://github.com/adplug/libbinio/releases/download/libbinio-1.5/libbinio-1.5.tar.bz2' \
  '398b2468e7838d2274d1f62dbc112e7e043433812f7ae63ef29f5cb31dc6defd'
fetch adplug \
  'https://github.com/adplug/adplug/releases/download/adplug-2.4/adplug-2.4.tar.bz2' \
  'de18463bf7c0cb639a3228ad47e69eb7f78a5a197802d325f3a5ed7e1c56d57f'
fetch asap \
  'https://downloads.sourceforge.net/project/asap/asap/8.0.0/asap-8.0.0.tar.gz' \
  '062d7db2a0747bf9200560141452f8fa2289909b147ac40a5bb5b60d5275a14f'
fetch v2m \
  'https://github.com/Sound-Linux-More/v2mplayer/archive/2d6b6aaa880380a3945e1a314c4cf45099bc747d.tar.gz' \
  '27a2031c7431f74633fcbdfbb32974f2905480903e077b9c6fe4f40da783d4f8'
install_vendor ahx2play ahx2play-6861c29-orz.tar.gz \
  '438b7c034e714c9c72d77c9061ca01be216f95b24d05e8f8afa00310241fd9bb'
install_vendor sc68 sc68-webaudio68-2.2.1-orz.tar.gz \
  '82a8723a70e20214088a1bc676f7b71afa1d0aad4e5cda06f706dae3137b8864'

printf '[SOURCE] All full-profile decoder sources are ready.\n'
