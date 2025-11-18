// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MosaicKit",
    platforms: [.macOS(.v15), .iOS(.v18), .macCatalyst(.v17)],
    products: [
        .library(
            name: "MosaicKit",
            targets: ["MosaicKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/DenDmitriev/DominantColors.git", .upToNextMajor(from: "1.2.0"))
    ],
    targets: [
        .target(
            name: "MosaicKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "DominantColors", package: "DominantColors")
            ],
            path: "Sources",
            resources: [
                .process("Shaders")
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(
            name: "MetalPerformance",
            dependencies: ["MosaicKit"],
            path: "Tests/MetalPerformance"
        )
    ]
)

