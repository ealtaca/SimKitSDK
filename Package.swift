// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
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
