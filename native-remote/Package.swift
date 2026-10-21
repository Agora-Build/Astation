// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AstationRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AstationRemote", targets: ["AstationRemote"])],
    dependencies: [
        .package(path: "../build/atem-client/edeb8f0fab71d4573e41c4ca7935aab207200caf/AtemClient")
    ],
    targets: [
        .target(name: "AstationRemote", dependencies: [.product(name: "AtemClient", package: "AtemClient")]),
        .testTarget(name: "AstationRemoteTests", dependencies: ["AstationRemote"], resources: [.copy("Fixtures")])
    ]
)
