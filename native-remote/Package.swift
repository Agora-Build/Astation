// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AstationRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AstationRemote", targets: ["AstationRemote"])],
    dependencies: [
        .package(path: "../build/atem-client/2b0c384e7213e5d4637cdba1f0a78ccbc53a2083/AtemClient")
    ],
    targets: [
        .target(name: "AstationRemote", dependencies: [.product(name: "AtemClient", package: "AtemClient")]),
        .testTarget(name: "AstationRemoteTests", dependencies: ["AstationRemote"], resources: [.copy("Fixtures")])
    ]
)
