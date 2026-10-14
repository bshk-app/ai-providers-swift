// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DictatorSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DictatorCore", targets: ["DictatorCore"]),
        .library(name: "DictatorAppleAuth", targets: ["DictatorAppleAuth"])
    ],
    targets: [
        .target(name: "DictatorCore"),
        .target(name: "DictatorAppleAuth", dependencies: ["DictatorCore"]),
        .testTarget(name: "DictatorCoreTests", dependencies: ["DictatorCore", "DictatorAppleAuth"])
    ]
)
