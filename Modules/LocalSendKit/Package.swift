// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalSendKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalSendKit", targets: ["LocalSendKit"])
    ],
    dependencies: [
        .package(path: "../AppLogging"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.3.0")
    ],
    targets: [
        .target(
            name: "LocalSendKit",
            dependencies: [
                "AppLogging",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .testTarget(name: "LocalSendKitTests", dependencies: ["LocalSendKit", "AppLogging"])
    ]
)
