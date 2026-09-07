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
        ),
        // Opt-in WebP support. Kept out of the `MosaicKit` product because it's
        // the only thing in this package's dependency graph that pulls in a
        // binary xcframework (webp.swift -> libwebp-ios), and a binary
        // xcframework in a target's graph breaks Xcode SwiftUI Preview's
        // JIT/dylib-patch execution for every client that links it — including
        // ones that never touch WebP. Link this product too, and call
        // `MosaicKitWebP.register()` at startup, only if you need `.webp`
        // output at runtime.
        .library(
            name: "MosaicKitWebP",
            targets: ["MosaicKitWebP"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/DenDmitriev/DominantColors.git", .upToNextMajor(from: "1.2.0")),
        .package(url: "https://github.com/samsonjs/SJSAssetExportSession.git", .upToNextMajor(from: "0.4.0")),
        .package(url: "https://github.com/awxkee/webp.swift.git", from: "1.1.2")
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
        ),
        .target(
            name: "MosaicKitWebP",
            dependencies: [
                "MosaicKit",
                .product(name: "webp", package: "webp.swift")
            ],
            path: "SourcesWebP"
        ),
        .testTarget(
            name: "MosaicKitTests",
            dependencies: ["MosaicKit", "MosaicKitWebP"],
            path: "Tests/MosaicKitTests",
            resources: [
                .process("embeddedAsset")
            ]
        )
    ]
)
