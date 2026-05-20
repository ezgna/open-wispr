// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "open-wispr",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "WhisperBridge",
            path: "Sources/WhisperBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/opt/homebrew/opt/ggml/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/ggml/lib",
                ]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
            ]
        ),
        .target(
            name: "OpenWisprLib",
            dependencies: ["WhisperBridge"],
            path: "Sources/OpenWisprLib",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "open-wispr",
            dependencies: ["OpenWisprLib"],
            path: "Sources/OpenWispr"
        ),
        .testTarget(
            name: "OpenWisprTests",
            dependencies: ["OpenWisprLib"],
            path: "Tests/OpenWisprTests"
        ),
    ]
)
