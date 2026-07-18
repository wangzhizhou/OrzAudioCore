# OrzAudioCore 独立仓库迁移清单

当前仓库已经将 SDK 边界固定，迁移时应保留以下目录和文件：

- `Sources/OrzAudioKitCXX/`：核心、decoder 和公共 C ABI。
- `Sources/OrzAudioKit/`：官方 Swift binding；迁移后删除 OrzMusic 专用的兼容 facade。
- `SDK/Web/`：TypeScript binding 和 npm package。
- `decoder-manifest.json` 与 `script/generate-decoder-manifest.mjs`。
- `CMakeLists.txt`、`CMakePresets.json`、`cmake/` 和 SDK build/package scripts。
- `Tests/SDK/` 及从 `DecoderInvariantTests` 拆出的 PCM fixtures/conformance tests。
- 根 `LICENSE`、所有第三方 license 及 decoder 来源历史。

## 首个独立版本门禁

1. 在 macOS 与 Linux 运行 builtin-lite ABI、12 实例和 ASan/UBSan tests。
2. 构建 full macOS SDK、lite XCFramework 和 full/lite WASM。
3. 编译 Swift、TypeScript 和安装后 Linux CMake consumer。
4. 为相同 fixtures 生成旧内嵌核心与 SDK ABI v1 PCM 报告。
5. 运行 `package-sdk.sh`，校验 manifest、SBOM、license 和 checksum。
6. 发布 `1.0.0-rc.1`，OrzMusic 通过不可变 tag/checksum 固定依赖。

## OrzMusic 双轨期

- 双轨期不少于一个 release cycle。
- 每个 decoder 至少一个真实 fixture，整数路径比较 hash，浮点路径记录最大绝对误差。
- 持续验证连续切歌、seek、cancel、12 路并行和缓存失效。
- 只有当 SDK 可独立回滚且 PCM 报告达标后，才删除 OrzMusic 中的 decoder 源码、旧 ABI 和重复构建脚本。

Android/Windows 不阻塞 1.0；它们作为后续 minor release，不改变 C ABI major。

## 可重复导出

从 OrzMusic 工作树导出独立仓库内容：

```bash
./script/export-audio-core.sh /path/to/empty/OrzAudioCore
```

导出只包含核心 C/C++ 源码、官方 Swift/TypeScript binding、第三方头文件、
构建发布脚本、manifest、SDK 测试与文档。Vapor、CAS、播放器 UI 和旧 Swift
兼容 facade 不会进入独立仓库。导出目录应先通过 CMake 与 SwiftPM 测试，再
创建 tag 或发布制品。
