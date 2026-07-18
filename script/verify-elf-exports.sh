#!/usr/bin/env bash
set -euo pipefail

lib="${1:?usage: verify-elf-exports.sh /path/to/libOrzAudioCore.so}"
actual="$(nm -D --defined-only "$lib" | awk '{print $3}' | sed 's/@@.*//' | grep '^orz_' | sort)"
expected="$(sed -n '/global:/,/local:/p' "$(dirname "$0")/../cmake/orz-audio-core.map" \
  | sed -n 's/^[[:space:]]*\(orz_[A-Za-z0-9_]*\);/\1/p' | sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Unexpected OrzAudioCore ELF exports" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

unexpected="$(nm -D --defined-only "$lib" | awk '{print $3}' | grep -vE '^(ORZ_AUDIO_CORE_|orz_)' || true)"
if [[ -n "$unexpected" ]]; then
  echo "Third-party symbols are publicly exported:" >&2
  printf '%s\n' "$unexpected" >&2
  exit 1
fi

if ! readelf -d "$lib" | grep -qE 'Shared library: \[libz\.so'; then
  echo "OrzAudioCore full ELF is missing its zlib DT_NEEDED dependency" >&2
  exit 1
fi

printf 'Verified %s exports only the ABI v1 symbol set\n' "$lib"
