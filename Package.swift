// swift-tools-version: 5.9
import PackageDescription

// Base path for Agora RTC SDK xcframeworks (macOS arm64/x86_64 universal)
let agoraLibs = "third_party/agora/rtc_mac/libs"
let agoraPlatform = "macos-arm64_x86_64"

// Each xcframework contains a .framework for the target platform
let agoraFrameworkDirs: [String] = [
    "\(agoraLibs)/AgoraRtcKit.xcframework/\(agoraPlatform)",
    "\(agoraLibs)/aosl.xcframework/\(agoraPlatform)",
    "\(agoraLibs)/Agoraffmpeg.xcframework/\(agoraPlatform)",
    "\(agoraLibs)/Agorafdkaac.xcframework/\(agoraPlatform)",
    "\(agoraLibs)/AgoraSoundTouch.xcframework/\(agoraPlatform)",
    "\(agoraLibs)/AgoraScreenCaptureExtension.xcframework/\(agoraPlatform)",
    "\(agoraLibs)/AgoraAiNoiseSuppressionExtension.xcframework/\(agoraPlatform)",
]

// Build linker flags: -L for static lib, -F for framework search, -rpath for runtime
var linkerFlags: [String] = ["-L", "build"]
for dir in agoraFrameworkDirs {
    linkerFlags += ["-F", dir]
    // Runtime search path so dyld finds the frameworks during development
    linkerFlags += ["-Xlinker", "-rpath", "-Xlinker", dir]
}
// Standard rpath for .app bundle deployment
linkerFlags += ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]

let package = Package(
    name: "Astation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "astation",
            targets: ["Menubar"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
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
                .product(name: "NIO", package: "swift-nio")
            ],
            path: "Sources/Menubar",
            linkerSettings: [
                .unsafeFlags(linkerFlags),
                .linkedLibrary("astation_core"),
                .linkedLibrary("c++"),
                .linkedFramework("AgoraRtcKit"),
                .linkedFramework("aosl"),
                .linkedFramework("Agoraffmpeg"),
                .linkedFramework("Agorafdkaac"),
                .linkedFramework("AgoraSoundTouch"),
                .linkedFramework("AgoraScreenCaptureExtension"),
            ]
        ),
        .testTarget(
            name: "AstationTests",
            dependencies: ["Menubar"],
            path: "Tests/AstationTests"
        )
    ]
)
