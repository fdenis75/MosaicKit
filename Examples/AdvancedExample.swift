import MosaicKit
import Foundation

/// Advanced example showing different configurations and layouts
// @available(macOS 26, iOS 26, *)
struct AdvancedExample {

    static func run() async throws {
        print("🎬 MosaicKit - Advanced Example")
        print("=" * 50)

        let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        // Load video
        print("\n📹 Loading video...")
        let video = try await VideoInput(from: videoURL)
        print("   \(video.title)")

        let generator = try MetalMosaicGenerator()

        // Example 1: Quick Preview
        print("\n1️⃣ Generating quick preview...")
        try await generateQuickPreview(
            video: video,
            generator: generator,
            outputDir: outputDir
        )

        // Example 2: High Quality
        print("\n2️⃣ Generating high-quality mosaic...")
        try await generateHighQuality(
            video: video,
            generator: generator,
            outputDir: outputDir
        )

        // Example 3: Square Format
        print("\n3️⃣ Generating square format...")
        try await generateSquare(
            video: video,
            generator: generator,
            outputDir: outputDir
        )

        // Example 4: iPhone Optimized
        print("\n4️⃣ Generating iPhone-optimized...")
        try await generateForIPhone(
            video: video,
            generator: generator,
            outputDir: outputDir
        )

        // Example 5: Custom Layout
        print("\n5️⃣ Generating with custom layout...")
        try await generateCustomLayout(
            video: video,
            generator: generator,
            outputDir: outputDir
        )

        // Example 6: Full Overlay Annotations
        print("\n6️⃣ Generating with overlay annotations...")
        try await generateWithOverlays(
            video: video,
            generator: generator,
            outputDir: outputDir
        )

        print("\n" + "=" * 50)
        print("🎉 All examples complete!")
    }

    // MARK: - Example Configurations

    static func generateQuickPreview(
        video: VideoInput,
        generator: MetalMosaicGenerator,
        outputDir: URL
    ) async throws {
        var config = MosaicConfiguration(
            width: 2000,
            density: .xl,
            format: .jpeg,
            includeMetadata: false,
            useAccurateTimestamps: false,
            compressionQuality: 0.4
        )
        config.outputdirectory = outputDir

        let startTime = Date()
        let url = try await generator.generate(for: video, config: config)
        let elapsed = Date().timeIntervalSince(startTime)

        print("   ✅ Quick preview (\(String(format: "%.1f", elapsed))s)")
        print("   → \(url.lastPathComponent)")
    }

    static func generateHighQuality(
        video: VideoInput,
        generator: MetalMosaicGenerator,
        outputDir: URL
    ) async throws {
        var config = MosaicConfiguration(
            width: 8000,
            density: .xs,
            format: .heif,
            includeMetadata: true,
            useAccurateTimestamps: true,
            compressionQuality: 0.6
        )
        config.outputdirectory = outputDir

        let startTime = Date()
        let url = try await generator.generate(for: video, config: config)
        let elapsed = Date().timeIntervalSince(startTime)

        print("   ✅ High quality (\(String(format: "%.1f", elapsed))s)")
        print("   → \(url.lastPathComponent)")
    }

    static func generateSquare(
        video: VideoInput,
        generator: MetalMosaicGenerator,
        outputDir: URL
    ) async throws {
        var config = MosaicConfiguration(
            width: 3000,
            density: .m,
            format: .jpeg,
            compressionQuality: 0.8
        )
        config.layout.aspectRatio = .square
        config.outputdirectory = outputDir

        let startTime = Date()
        let url = try await generator.generate(for: video, config: config)
        let elapsed = Date().timeIntervalSince(startTime)

        print("   ✅ Square format (\(String(format: "%.1f", elapsed))s)")
        print("   → \(url.lastPathComponent)")
    }

    static func generateForIPhone(
        video: VideoInput,
        generator: MetalMosaicGenerator,
        outputDir: URL
    ) async throws {
        var config = MosaicConfiguration(
            width: 1200,
            density: .s,
            format: .heif,
            compressionQuality: 0.4
        )
        config.outputdirectory = outputDir

        let startTime = Date()
        let url = try await generator.generate(
            for: video,
            config: config,
            forIphone: true
        )
        let elapsed = Date().timeIntervalSince(startTime)

        print("   ✅ iPhone optimized (\(String(format: "%.1f", elapsed))s)")
        print("   → \(url.lastPathComponent)")
    }

    static func generateCustomLayout(
        video: VideoInput,
        generator: MetalMosaicGenerator,
        outputDir: URL
    ) async throws {
        var config = MosaicConfiguration.default
        config.width = 6000
        config.layout.useCustomLayout = true
        config.layout.aspectRatio = .ultrawide
        config.layout.visual.addBorder = true
        config.layout.visual.borderColor = .white
        config.layout.visual.borderWidth = 2.0
        config.layout.visual.addShadow = true
        config.outputdirectory = outputDir

        let startTime = Date()
        let url = try await generator.generate(for: video, config: config)
        let elapsed = Date().timeIntervalSince(startTime)

        print("   ✅ Custom layout (\(String(format: "%.1f", elapsed))s)")
        print("   → \(url.lastPathComponent)")
    }

    /// Demonstrates the full OverlayConfiguration API:
    /// per-frame labels, metadata header band, text watermark, and Color DNA strip.
    static func generateWithOverlays(
        video: VideoInput,
        generator: MetalMosaicGenerator,
        outputDir: URL
    ) async throws {
        var config = MosaicConfiguration(
            width: 5120,
            density: .m,
            format: .heif,
            includeMetadata: true,
            compressionQuality: 0.6
        )
        config.outputdirectory = outputDir

        // --- Per-frame label: timestamp pill in the bottom-right corner ---
        config.overlay.frameLabel = FrameLabelConfig(
            show:            true,
            format:          .timestamp,   // show HH:MM:SS
            position:        .bottomRight,
            textColor:       MosaicColor(red: 1, green: 1, blue: 1),
            backgroundStyle: .pill
        )

        // --- Metadata header band with eight fields + a colour palette row ---
        config.overlay.header = HeaderConfig(
            fields: [
                .title,
                .duration,
                .resolution,
                .codec,
                .bitrate,
                .fileSize,
                .frameRate,
                .colorPalette(swatchCount: 8)   // dominant-colour swatches
            ],
            height: .fixed(80)                  // exact 80-pixel band
        )

        // --- Text watermark in the bottom-right corner ---
        config.overlay.watermark = WatermarkConfig(
            content:  .text("© My Studio"),
            position: .bottomRight,
            opacity:  0.35,
            scale:    0.10
        )

        // --- Color DNA gradient strip below the mosaic ---
        config.overlay.colorDNA = ColorDNAConfig(
            show:     true,
            height:   24,
            position: .bottom,
            style:    .gradient
        )

        let startTime = Date()
        let url = try await generator.generate(for: video, config: config)
        let elapsed = Date().timeIntervalSince(startTime)

        print("   ✅ Overlay annotations (\(String(format: "%.1f", elapsed))s)")
        print("   → \(url.lastPathComponent)")
    }
}

// MARK: - Progress Tracking Example

// @available(macOS 26, iOS 26, *)
struct ProgressTrackingExample {

    static func run() async throws {
        print("🎬 MosaicKit - Progress Tracking Example")
        print("=" * 50)

        let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        // Setup
        let video = try await VideoInput(from: videoURL)
        var config = MosaicConfiguration.default
        config.outputdirectory = outputDir

        let generator = try MetalMosaicGenerator()

        // Set progress handler
        await generator.setProgressHandler(for: video) { progress in
            let percentage = Int(progress * 100)
            let barLength = 40
            let filled = Int(Double(barLength) * progress)
            let bar = String(repeating: "█", count: filled) +
                     String(repeating: "░", count: barLength - filled)

            print("\r   [\(bar)] \(percentage)%", terminator: "")
            fflush(stdout)
        }

        // Generate
        print("\n🎨 Generating with progress tracking...")
        let url = try await generator.generate(for: video, config: config)

        print("\n✅ Complete!")
        print("   → \(url.path)")
    }
}

// MARK: - Error Handling Example

// @available(macOS 26, iOS 26, *)
struct ErrorHandlingExample {

    static func run() async {
        print("🎬 MosaicKit - Error Handling Example")
        print("=" * 50)

        let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        do {
            // Try to create generator
            let generator = try MetalMosaicGenerator()

            // Try to load video
            print("\n📹 Loading video...")
            let video = try await VideoInput(from: videoURL)

            // Try to generate mosaic
            print("🎨 Generating mosaic...")
            var config = MosaicConfiguration.default
            config.outputdirectory = outputDir

            let url = try await generator.generate(for: video, config: config)

            print("✅ Success: \(url.path)")

        } catch MosaicError.metalNotSupported {
            print("❌ Metal is not available on this device")
            print("   Your device must support Metal for mosaic generation")

        } catch MosaicError.invalidVideo(let message) {
            print("❌ Invalid video: \(message)")
            print("   Please check that the video file is valid and accessible")

        } catch MosaicError.layoutCreationFailed(let error) {
            print("❌ Layout creation failed: \(error.localizedDescription)")
            print("   Try adjusting the configuration parameters")

        } catch MosaicError.saveFailed(let url, let error) {
            print("❌ Failed to save mosaic to \(url.path)")
            print("   Error: \(error.localizedDescription)")
            print("   Check that the output directory exists and is writable")

        } catch MosaicError.invalidDimensions(let size) {
            print("❌ Invalid dimensions: \(size)")
            print("   Check your width and aspect ratio settings")

        } catch {
            print("❌ Unexpected error: \(error.localizedDescription)")
        }
    }
}
