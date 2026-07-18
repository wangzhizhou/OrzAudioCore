# OrzAudioCore SDK

OrzAudioCore 是 OrzMusic 下沉的跨平台解码边界。SDK 只负责格式探测、元数据、subsong/seek 和 PCM 解码；播放设备、队列、HTTP、CAS 与 WAV 缓存仍属于应用层。

## 稳定接口

公共 ABI 位于 `orz_audio_core.h`，当前 ABI 为 1.0。所有公共结构都包含 `struct_size` 与 `abi_version`；调用端必须先填写这两个字段。ABI major 不一致时返回 `ORZ_ERROR_ABI_MISMATCH`。

句柄拥有创建后仍需使用的输入字节，因此调用端在 `orz_decoder_create_memory` 返回后即可释放输入。不同句柄可以并行，同一句柄由调用端串行访问。PCM 输出为 decoder 原生采样率、interleaved float32，SDK 不做隐式重采样。

旧的 `orz_load/orz_render` 和早期 handle API 只作为一个迁移周期的兼容入口。新代码必须使用 `orz_decoder_create_memory`、`orz_decoder_get_stream_info` 和 `orz_decoder_render_f32`。

## 能力与版本

`decoder-manifest.json` 是 decoder ID、版本、分类、profile 和导航能力的单一数据源。修改后运行：

```bash
node script/generate-decoder-manifest.mjs
```

CI 使用 `--check` 阻止提交过期的注册表或 build info。`orz_build_info()` 返回 SDK semver、ABI 和缓存 fingerprint；OrzMusic 服务端把 fingerprint 写入 PCM WAV 缓存键。

播放策略不属于 SDK。`directFile/wasmDecode/serverDecode` 由 OrzMusic 根据浏览器能力和性能要求决定。

## 构建与消费

```bash
# 无第三方依赖的 BP/MIDI/YM SDK，并运行 C/C++ consumer 测试
./script/build-sdk.sh builtin-lite

# 当前主机完整 SDK
./script/build-sdk.sh macos-arm64

# Swift Package 产品
swift build --product OrzAudioCore

# TypeScript 类型检查
cd SDK/Web && npm run build

# 校验 manifest、npm lockfile、CMake 与发布版本一致性
node script/check-release-readiness.mjs

# 组装可发布的 native SDK tarball、checksum 和 CycloneDX SBOM
./script/package-sdk.sh builtin-lite
```

CMake 输出 `OrzAudioCore::OrzAudioCore` target，并可安装公共头文件和 CMake package。Swift 使用 `AudioDecoder`；Web 包使用 `createDecoder()`，负责 WASM 内存和句柄生命周期。

Apple mobile 当前提供 dependency-free profile 的 device/simulator preset。完整第三方 decoder 的 iOS archive 在独立 SDK 仓库接入各依赖的交叉编译后合并为 XCFramework。

## 发布规则

- ABI 破坏性修改：major。
- 新格式、能力或向后兼容字段：minor。
- decoder 修复：patch。
- 每次发布必须附 decoder manifest、第三方许可证、checksum、ABI consumer 结果和 PCM conformance 报告。
- `package-sdk.sh` 会生成安装树、manifest、license、CycloneDX SBOM、tarball 和 SHA-256 checksum，作为后续 release job 的唯一输入。
- `check-release-readiness.mjs` 必须在 CI 与 tag release 中通过；带 `-` 的版本发布为 prerelease，稳定语义版本自动发布为 latest release。
- OrzMusic 固定依赖 SDK 版本；升级后旧缓存因 fingerprint 变化自动失效，可通过依赖版本直接回滚。
