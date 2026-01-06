// swift-tools-version:5.9
// SimKit SDK v1.0.3
import PackageDescription

let package = Package(
    name: "SimKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "SimKit",
            targets: ["SimKit"]
        ),
    ],
    targets: [
        .target(
            name: "SimKit",
            dependencies: [],
            path: "Sources/SimKit"
        ),
        .testTarget(
            name: "SimKitTests",
            dependencies: ["SimKit"],
            path: "Tests/SimKitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
