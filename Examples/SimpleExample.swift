import MosaicKit
import Foundation

/// Simplest possible example using the high-level API
@main
struct SimpleExample {
    static func main() async throws {
        print("🎬 MosaicKit - Simple Example")
        print("=" * 50)

        // 1. Setup paths
        let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        // 2. Generate mosaic in one step
        print("\n🎨 Generating mosaic...")

        let generator = try MosaicGenerator()
        let config = MosaicConfiguration.default

        let startTime = Date()
        let mosaicURL = try await generator.generate(
            from: videoURL,
            config: config,
            outputDirectory: outputDir
        )
        let elapsed = Date().timeIntervalSince(startTime)

        // 3. Done!
        print("\n✅ Success!")
        print("   Generated in: \(String(format: "%.1f", elapsed))s")
        print("   Saved to: \(mosaicURL.path)")

        print("\n" + "=" * 50)
        print("🎉 That's it!")
    }
}

// MARK: - Even Simpler with Custom Configuration

// @available(macOS 26, iOS 26, *)
struct SimplestExample {
    static func run() async throws {
        // The absolute simplest example - 5 lines!
        let generator = try MosaicGenerator()
        let mosaicURL = try await generator.generate(
            from: URL(fileURLWithPath: "/path/to/video.mp4"),
            config: .default,
            outputDirectory: URL(fileURLWithPath: "/path/to/output")
        )
        print("Done: \(mosaicURL.path)")
    }
}

// MARK: - Simple with Custom Settings

// @available(macOS 26, iOS 26, *)
struct SimpleWithConfig {
    static func run() async throws {
        print("🎬 Simple Example with Custom Settings\n")

        // Create custom configuration
        var config = MosaicConfiguration(
            width: 4000,
            density: .m,
            format: .heif
        )

        // Generate
        let generator = try MosaicGenerator()
        let mosaicURL = try await generator.generate(
            from: URL(fileURLWithPath: "/path/to/video.mp4"),
            config: config,
            outputDirectory: URL(fileURLWithPath: "/path/to/output")
        )

        print("✅ Saved: \(mosaicURL.lastPathComponent)")
    }
}

// MARK: - Simple with Overlay Annotations

// @available(macOS 26, iOS 26, *)
struct SimpleWithOverlay {
    static func run() async throws {
        print("🎬 Simple Example with Overlay Annotations\n")

        var config = MosaicConfiguration(
            width: 4000,
            density: .m,
            format: .heif,
            includeMetadata: true
        )

        // Per-frame timestamp pill
        config.overlay.frameLabel = FrameLabelConfig(format: .timestamp, position: .bottomRight)

        // Metadata header with four fields
        config.overlay.header = HeaderConfig(
            fields: [.title, .duration, .resolution, .colorPalette(swatchCount: 6)],
            height: .fixed(60)
        )

        // Translucent text watermark
        config.overlay.watermark = WatermarkConfig(
            content: .text("© My Studio"), position: .bottomRight, opacity: 0.35, scale: 0.10
        )

        // Color DNA strip at the bottom
        config.overlay.colorDNA = ColorDNAConfig(show: true, height: 24, position: .bottom, style: .gradient)

        let generator = try MosaicGenerator()
        let mosaicURL = try await generator.generate(
            from: URL(fileURLWithPath: "/path/to/video.mp4"),
            config: config,
            outputDirectory: URL(fileURLWithPath: "/path/to/output")
        )

        print("✅ Saved: \(mosaicURL.lastPathComponent)")
    }
}

// MARK: - Simple Batch Processing

// @available(macOS 26, iOS 26, *)
struct SimpleBatch {
    static func run() async throws {
        print("🎬 Simple Batch Processing\n")

        let videoURLs = [
            URL(fileURLWithPath: "/path/to/video1.mp4"),
            URL(fileURLWithPath: "/path/to/video2.mp4"),
            URL(fileURLWithPath: "/path/to/video3.mp4")
        ]

        let generator = try MosaicGenerator()

        let mosaicURLs = try await generator.generateBatch(
            from: videoURLs,
            config: .default,
            outputDirectory: URL(fileURLWithPath: "/path/to/output")
        ) { completed, total in
            print("Progress: \(completed)/\(total)")
        }

        print("\n✅ Generated \(mosaicURLs.count) mosaics!")
        for url in mosaicURLs {
            print("   • \(url.lastPathComponent)")
        }
    }
}
