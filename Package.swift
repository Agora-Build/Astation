// swift-tools-version: 5.9
import PackageDescription

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
                .unsafeFlags(["-L", "build"]),
                .linkedLibrary("astation_core"),
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "AstationTests",
            dependencies: ["Menubar"],
            path: "Tests/AstationTests"
        )
    ]
)
