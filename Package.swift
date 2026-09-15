// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AppStats",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .visionOS(.v1),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "AppStats",
            targets: ["AppStats"]
        )
    ],
    dependencies: [
        // No external dependencies - keep SDK lightweight
    ],
    targets: [
        .target(
            name: "AppStats",
            dependencies: [],
            path: "Sources/AppStats",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "AppStatsTests",
            dependencies: ["AppStats"],
            path: "Tests/AppStatsTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
