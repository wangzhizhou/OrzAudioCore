// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrzAudioCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
    ],
    products: [
        .library(name: "OrzAudioCore", targets: ["OrzAudioCore"]),
        .library(name: "OrzAudioCoreC", targets: ["OrzAudioKitCXX"]),
    ],
    targets: [
        // SwiftPM intentionally provides the dependency-free builtin-lite
        // profile. Full/server profiles are distributed through CMake-built
        // binaries so every third-party decoder version stays locked.
        .target(
            name: "OrzAudioKitCXX",
            path: "Sources/OrzAudioKitCXX",
            exclude: [
                "adplug", "asap", "gme", "helpers", "openmpt", "sc68",
                "sidplayfp", "uade", "v2m",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("dispatch"),
            ],
            cxxSettings: [
                .headerSearchPath("dispatch"),
            ]
        ),
        .target(
            name: "OrzAudioCore",
            dependencies: ["OrzAudioKitCXX"],
            path: "Sources/OrzAudioKit"
        ),
        .testTarget(
            name: "OrzAudioCoreTests",
            dependencies: ["OrzAudioCore"],
            path: "Tests/OrzAudioCoreTests"
        ),
    ]
)
