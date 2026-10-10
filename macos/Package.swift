// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DossiaryScanHelper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HelperCore", path: "Sources/HelperCore"),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore"], path: "Tests/HelperCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
