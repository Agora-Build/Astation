// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AstationRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AstationRemote", targets: ["AstationRemote"])],
    dependencies: [
        .package(path: "../build/atem-client/04140840fc0cec4086072ab6326b7a1b46b25be4/AtemClient")
    ],
    targets: [
        .target(name: "AstationRemote", dependencies: [.product(name: "AtemClient", package: "AtemClient")]),
        .testTarget(name: "AstationRemoteTests", dependencies: ["AstationRemote"], resources: [.copy("Fixtures")])
    ]
)
