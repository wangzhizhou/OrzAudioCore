# OrzAudioCore

OrzAudioCore is the cross-platform decoding SDK used by OrzMusic. It exposes a
stable, versioned C ABI and official Swift and TypeScript bindings. Decoder
instances are isolated and different instances can render concurrently.

## Build

The dependency-free builtin profile (YM, MIDI and SoundMon BP):

```bash
cmake --preset builtin-lite
cmake --build --preset builtin-lite
ctest --test-dir .cmake-build/builtin-lite --output-on-failure
swift test
```

The `full` and `server` profiles require the locked native decoder archives in
`Libraries/OrzAudioKit/native`. Build those archives with
`script/build-native-libs.sh`, then select the matching CMake preset.

The stable public API is documented in `docs/orz-audio-core.md`. Format and
decoder capabilities are generated from `decoder-manifest.json`.

Before tagging a release, validate every package projection and generated file:

```bash
node script/check-release-readiness.mjs
node script/generate-decoder-manifest.mjs --check
```

## Packages

- C/C++: CMake install package and pkg-config metadata.
- Swift: source package and iOS XCFramework for builtin-lite; versioned full-profile macOS SDK tarball.
- Web: `SDK/Web`, published as `@orzmusic/audio-core` with versioned WASM assets.

OrzAudioCore contains decoding, probing, metadata, seek and PCM rendering only.
Playback devices, queues, HTTP, CAS and UI remain responsibilities of consumers.

## License

OrzAudioCore is licensed under Apache-2.0. Bundled decoder dependencies retain
their respective licenses; release artifacts include their notices and SBOM.
