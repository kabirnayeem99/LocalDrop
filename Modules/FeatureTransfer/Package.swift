// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FeatureTransfer",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeatureTransfer", targets: ["FeatureTransfer"])
    ],
    dependencies: [
        .package(path: "../AppLogging"),
        .package(path: "../LocalSendKit"),
        .package(path: "../DesignSystem")
    ],
    targets: [
        .target(
            name: "FeatureTransfer",
            dependencies: ["AppLogging", "LocalSendKit", "DesignSystem"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(name: "FeatureTransferTests", dependencies: ["FeatureTransfer", "AppLogging"])
    ]
)
