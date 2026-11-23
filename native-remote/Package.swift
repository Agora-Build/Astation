// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AstationRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AstationRemote", targets: ["AstationRemote"])],
    dependencies: [
        .package(path: "../build/atem-client/1952ec8ad03fe6c613ce60a8d5b620b93712f8bf/AtemClient")
    ],
    targets: [
        .target(name: "AstationRemote", dependencies: [.product(name: "AtemClient", package: "AtemClient")]),
        .testTarget(name: "AstationRemoteTests", dependencies: ["AstationRemote"], resources: [.copy("Fixtures")])
    ]
)
