// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AstationRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AstationRemote", targets: ["AstationRemote"])],
    dependencies: [
        .package(path: "../build/atem-client/1493ca6a5d704484bff7b30b09222cf20658fdcd/AtemClient")
    ],
    targets: [
        .target(name: "AstationRemote", dependencies: [.product(name: "AtemClient", package: "AtemClient")]),
        .testTarget(name: "AstationRemoteTests", dependencies: ["AstationRemote"], resources: [.copy("Fixtures")])
    ]
)
