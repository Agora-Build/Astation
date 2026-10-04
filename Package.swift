// swift-tools-version: 5.9
import PackageDescription
import Foundation

let executableInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Config/Info.plist").path

let package = Package(
    name: "Astation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "astation",
            targets: ["Menubar"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_macOS.git", from: "4.6.2"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9")
    ],
    targets: [
        .target(
            name: "CStationCore",
            path: "Sources/CStationCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Menubar",
            dependencies: [
                "CStationCore",
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "RtcBasic", package: "AgoraRtcEngine_macOS"),
                .product(name: "ScreenCapture", package: "AgoraRtcEngine_macOS"),
                .product(name: "AINS", package: "AgoraRtcEngine_macOS"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Menubar",
            resources: [.copy("Resources/transcription-model.json"), .copy("Resources/whisper-large-v3-turbo-coreml-v1.json"),
                        .copy("Resources/whisper-large-v3-coreml-v1.json")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", executableInfoPlist]),
                .unsafeFlags(["-L", "build"]),
                .linkedLibrary("astation_core"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "AstationTests",
            dependencies: ["Menubar"],
            path: "Tests/AstationTests"
        )
    ]
)
