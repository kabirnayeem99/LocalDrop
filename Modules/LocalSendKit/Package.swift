// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalSendKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalSendKit", targets: ["LocalSendKit"])
    ],
    targets: [
        .target(name: "LocalSendKit"),
        .testTarget(name: "LocalSendKitTests", dependencies: ["LocalSendKit"])
    ]
)
