// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AIProviders", defaultLocalization: "en", platforms: [.macOS(.v14), .iOS(.v18)],
    products: ["AIProvidersCore", "AIProvidersAuth", "AITextProviders", "AISpeechProviders", "AIServiceProviders", "AIProviderViews", "DictatorCore", "DictatorAppleAuth"].map { .library(name: $0, targets: [$0]) },
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
        .target(name: "AIProviderViews", dependencies: ["AIProvidersCore"], resources: [.process("Resources")]),
        .testTarget(name: "AIProviderViewsTests", dependencies: ["AIProviderViews"]),
        .testTarget(name: "AIProvidersTests", dependencies: ["AIProvidersCore", "AIProvidersAuth", "AITextProviders", "AISpeechProviders", "AIServiceProviders"])
    ], swiftLanguageModes: [.v5])
