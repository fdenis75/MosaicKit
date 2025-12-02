import MosaicKit
import Foundation

/// Basic example of generating a single mosaic
@available(macOS 26, iOS 26, *)
@main
struct BasicExample {
    static func main() async throws {
        print("🎬 MosaicKit - Basic Example")
        print("=" * 50)

        // 1. Setup paths
        let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        // 2. Create video input
        print("\n📹 Loading video...")
        let video = try await VideoInput(from: videoURL)

        print("   Title: \(video.title)")
        print("   Duration: \(String(format: "%.1f", video.duration ?? 0))s")
        if let width = video.width, let height = video.height {
            print("   Resolution: \(Int(width))x\(Int(height))")
        }
        if let size = video.fileSize {
            let sizeMB = Double(size) / 1_048_576.0
            print("   File Size: \(String(format: "%.1f", sizeMB)) MB")
        }

        // 3. Configure mosaic settings
        print("\n⚙️  Configuring mosaic...")
        var config = MosaicConfiguration(
            width: 5000,
            density: .m,
            format: .heif,
            includeMetadata: true,
            useAccurateTimestamps: true,
            compressionQuality: 0.4
        )
        config.outputdirectory = outputDir

        print("   Width: \(config.width)px")
        print("   Density: \(config.density.name) (\(config.density.thumbnailCountDescription))")
        print("   Format: \(config.format.rawValue)")
        print("   Compression: \(Int(config.compressionQuality * 100))%")

        // 4. Generate mosaic
        print("\n🎨 Generating mosaic...")
        let generator = try MetalMosaicGenerator()

        let startTime = Date()
        let mosaicURL = try await generator.generate(
            for: video,
            config: config
        )
        let elapsed = Date().timeIntervalSince(startTime)

        // 5. Display results
        print("\n✅ Success!")
        print("   Generated in: \(String(format: "%.1f", elapsed))s")
        print("   Saved to: \(mosaicURL.path)")

        // 6. Get file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: mosaicURL.path),
           let fileSize = attributes[.size] as? Int64 {
            let sizeMB = Double(fileSize) / 1_048_576.0
            print("   Output size: \(String(format: "%.1f", sizeMB)) MB")
        }

        // 7. Show performance metrics
        let metrics = await generator.getPerformanceMetrics()
        if let avgTime = metrics["averageGenerationTime"] as? Double {
            print("   Avg generation time: \(String(format: "%.1f", avgTime))s")
        }

        print("\n" + "=" * 50)
        print("🎉 Complete!")
    }
}
