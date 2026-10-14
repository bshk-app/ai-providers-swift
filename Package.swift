// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AIProviders", platforms: [.macOS(.v14), .iOS(.v18)],
    products: ["AIProvidersCore", "AIProvidersAuth", "AITextProviders", "AISpeechProviders", "AIServiceProviders", "DictatorCore", "DictatorAppleAuth"].map { .library(name: $0, targets: [$0]) },
    dependencies: [],
    targets: [
        .target(name: "DictatorCore", path: "Vendor/DictatorSDK/Sources/DictatorCore"),
        .target(name: "DictatorAppleAuth", dependencies: ["DictatorCore"], path: "Vendor/DictatorSDK/Sources/DictatorAppleAuth"),
        .testTarget(name: "DictatorCoreTests", dependencies: ["DictatorCore", "DictatorAppleAuth"], path: "Vendor/DictatorSDK/Tests/DictatorCoreTests"),
        .target(name: "AIProvidersCore"),
        .target(name: "AIProvidersAuth", dependencies: ["AIProvidersCore"]),
        .target(name: "AITextProviders", dependencies: ["AIProvidersCore"]),
        .target(name: "AISpeechProviders", dependencies: ["AIProvidersCore"]),
        .target(name: "AIServiceProviders", dependencies: ["AIProvidersCore", "DictatorCore"]),
        .testTarget(name: "AIProvidersTests", dependencies: ["AIProvidersCore", "AIProvidersAuth", "AITextProviders", "AISpeechProviders", "AIServiceProviders"])
    ], swiftLanguageModes: [.v5])
