// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FeatureTransfer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeatureTransfer", targets: ["FeatureTransfer"])
    ],
    dependencies: [
        .package(path: "../LocalSendKit"),
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(
            name: "FeatureTransfer",
            dependencies: ["LocalSendKit", "DesignSystem"]
        ),
        .testTarget(name: "FeatureTransferTests", dependencies: ["FeatureTransfer"])
    ]
)
