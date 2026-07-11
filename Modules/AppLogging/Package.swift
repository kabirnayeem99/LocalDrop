// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppLogging",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppLogging", targets: ["AppLogging"])
    ],
    targets: [
        .target(name: "AppLogging"),
        .testTarget(name: "AppLoggingTests", dependencies: ["AppLogging"])
    ]
)
