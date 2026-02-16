// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MosaicKit",
    platforms: [.macOS(.v26), .iOS(.v26), .macCatalyst(.v26)],
    products: [
        .library(
            name: "MosaicKit",
            targets: ["MosaicKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/DenDmitriev/DominantColors.git", .upToNextMajor(from: "1.2.0")),
        .package(url: "https://github.com/samsonjs/SJSAssetExportSession.git", .upToNextMajor(from: "0.4.0"))
    ],
    targets: [
        .target(
            name: "MosaicKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "DominantColors", package: "DominantColors"),
                .product(name: "SJSAssetExportSession", package: "SJSAssetExportSession")
            ],
            path: "Sources",
            resources: [
                .process("Shaders")
            ]
        )
    ]
)
