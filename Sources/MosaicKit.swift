import Foundation
import Logging
import CoreGraphics
/*#if os(macOS)
import Metal
#endif
*/
/// Main entry point for MosaicKit - Video Mosaic and Preview Generation Library
///
/// MosaicKit provides:
/// - **Mosaic Generation**: High-performance video mosaic generation with platform-specific optimizations
///   - macOS: Metal-accelerated GPU processing (default) or Core Graphics
///   - iOS: Core Graphics with vImage/Accelerate optimization (default)
/// - **Preview Generation**: Create condensed video previews from full-length videos
///
/// ## Usage
///
/// ### Mosaic Generation - Single Video (Default Generator)
/// ```swift
/// // Auto-selects Metal on macOS, Core Graphics on iOS
/// let generator = try MosaicGenerator()
/// let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
/// let outputDir = URL(fileURLWithPath: "/path/to/output")
///
/// let config = MosaicConfiguration.default
/// let mosaicURL = try await generator.generate(
///     from: videoURL,
///     config: config,
///     outputDirectory: outputDir
/// )
/// ```
///
/// ### Mosaic Generation - Choosing a Specific Generator
/// ```swift
/// // Use Core Graphics on macOS (instead of Metal)
/// let cgGenerator = try MosaicGenerator(preference: .preferCoreGraphics)
///
/// // Prefer Metal (macOS only, falls back to CG on iOS)
/// let metalGenerator = try MosaicGenerator(preference: .preferMetal)
/// ```
///
/// ### Mosaic Generation - Multiple Videos (Batch)
/// ```swift
/// let videoURLs = [url1, url2, url3]
/// let mosaicURLs = try await generator.generateBatch(
///     from: videoURLs,
///     config: config,
///     outputDirectory: outputDir
/// ) { completed, total in
///     print("Progress: \(completed)/\(total)")
/// }
/// ```
///
/// ### Preview Generation - Single Video
/// ```swift
/// let coordinator = PreviewGeneratorCoordinator()
/// let video = try await VideoInput(from: videoURL)
///
/// let config = PreviewConfiguration(
///     targetDuration: 60,  // 1 minute
///     density: .M,
///     format: .mp4,
///     includeAudio: true
/// )
///
/// let previewURL = try await coordinator.generatePreview(
///     for: video,
///     config: config
/// ) { progress in
///     print("\(progress.status.displayLabel): \(progress.progress * 100)%")
/// }
/// ```
///
/// ### Preview Generation - Batch Processing
/// ```swift
/// let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: 4)
/// let videos = try await videoURLs.asyncMap { try await VideoInput(from: $0) }
///
/// let results = try await coordinator.generatePreviewsForBatch(
///     videos: videos,
///     config: config
/// ) { progress in
///     print("\(progress.video.filename): \(progress.status.displayLabel)")
/// }
/// ```
///
/// ### Preview Generation - Composition for Video Player
/// ```swift
/// let generator = PreviewVideoGenerator()
/// let video = try await VideoInput(from: videoURL)
/// let config = PreviewConfiguration(targetDuration: 60, density: .M)
///
/// // Generate composition without exporting to file
/// let playerItem = try await generator.generateComposition(for: video, config: config)
///
/// // Use with AVPlayer for immediate playback
/// let player = AVPlayer(playerItem: playerItem)
/// player.play()
/// ```
@available(macOS 26, iOS 26, *)
public final class MosaicGenerator {
    private let logger = Logger(label: "com.mosaickit")
    private let internalGenerator: Any?
    private let generatorPreference: MosaicGeneratorFactory.GeneratorPreference

    /// Initialize a mosaic generator with default platform preference
    /// - Default: Metal on macOS, Core Graphics on iOS
    @available(macOS 26, iOS 26, *)
    public convenience init() throws {
        try self.init(preference: .auto)
    }

    /// Initialize a mosaic generator with specified preference
    /// - Parameter preference: The preferred generator implementation
    ///   - `.auto`: Metal on macOS, Core Graphics on iOS (default)
    ///   - `.preferMetal`: Metal (macOS only, falls back to Core Graphics on iOS)
    ///   - `.preferCoreGraphics`: Core Graphics (available on both platforms)
    @available(macOS 26, iOS 26, *)
    public init(preference: MosaicGeneratorFactory.GeneratorPreference) throws {
        self.generatorPreference = preference

        if #available(macOS 15, iOS 18, *) {
            self.internalGenerator = try MosaicGeneratorFactory.createGenerator(preference: preference)
        } else {
            self.internalGenerator = nil
            throw MosaicError.invalidConfiguration("MosaicKit requires macOS 15.0+ or iOS 18.0+")
        }
    }

    /// Generate a mosaic from a single video file
    /// - Parameters:
    ///   - videoURL: URL to the video file
    ///   - config: Mosaic generation configuration
    ///   - outputDirectory: Directory where the mosaic will be saved
    /// - Returns: URL to the generated mosaic file
    public func generate(
        from videoURL: URL,
        config: MosaicConfiguration,
        outputDirectory: URL
    ) async throws -> URL {
        logger.info("Generating mosaic from \(videoURL.lastPathComponent)")

        guard #available(macOS 15, iOS 18, *) else {
            throw MosaicError.invalidConfiguration("MosaicKit requires macOS 15.0+ or iOS 18.0+")
        }

        guard let generator = internalGenerator as? any MosaicGeneratorProtocol else {
            throw MosaicError.invalidConfiguration("Generator not available")
        }

        // Create VideoInput from URL
        logger.debug("Loading video metadata from \(videoURL.lastPathComponent)")
        let video = try await VideoInput(from: videoURL)

        // Update config with output directory
        var updatedConfig = config
        updatedConfig.outputdirectory = outputDirectory

        // Log which generator is being used
        switch generatorPreference {
        case .auto:
            #if os(macOS)
            logger.info("Generating mosaic with Metal acceleration (auto-selected)...")
            #else
            logger.info("Generating mosaic with Core Graphics acceleration (auto-selected)...")
            #endif
        case .preferMetal:
            logger.info("Generating mosaic with Metal acceleration (preferred)...")
        case .preferCoreGraphics:
            logger.info("Generating mosaic with Core Graphics acceleration (preferred)...")
        }

        // Generate mosaic using the selected generator
        let mosaicURL = try await generator.generate(
            for: video,
            config: updatedConfig,
            forIphone: false
        )

        logger.info("Mosaic generated successfully at \(mosaicURL.lastPathComponent)")
        return mosaicURL
    }

    /// Generate a mosaic image from a single video file without saving to disk
    /// - Parameters:
    ///   - videoURL: URL to the video file
    ///   - config: Mosaic generation configuration
    /// - Returns: The generated mosaic as a CGImage
    public func generateImage(
        from videoURL: URL,
        config: MosaicConfiguration
    ) async throws -> CGImage {
        logger.info("Generating mosaic image from \(videoURL.lastPathComponent)")

        guard #available(macOS 15, iOS 18, *) else {
            throw MosaicError.invalidConfiguration("MosaicKit requires macOS 15.0+ or iOS 18.0+")
        }

        guard let generator = internalGenerator as? any MosaicGeneratorProtocol else {
            throw MosaicError.invalidConfiguration("Generator not available")
        }

        // Create VideoInput from URL
        logger.debug("Loading video metadata from \(videoURL.lastPathComponent)")
        let video = try await VideoInput(from: videoURL)

        // Log which generator is being used
        switch generatorPreference {
        case .auto:
            #if os(macOS)
            logger.info("Generating mosaic image with Metal acceleration (auto-selected)...")
            #else
            logger.info("Generating mosaic image with Core Graphics acceleration (auto-selected)...")
            #endif
        case .preferMetal:
            logger.info("Generating mosaic image with Metal acceleration (preferred)...")
        case .preferCoreGraphics:
            logger.info("Generating mosaic image with Core Graphics acceleration (preferred)...")
        }

        // Generate mosaic image using the selected generator
        let mosaicImage = try await generator.generateMosaicImage(
            for: video,
            config: config,
            forIphone: false
        )

        logger.info("Mosaic image generated successfully")
        return mosaicImage
    }

    /// Generate mosaics from multiple video files
    /// - Parameters:
    ///   - videoURLs: Array of video file URLs
    ///   - config: Mosaic generation configuration
    ///   - outputDirectory: Directory where mosaics will be saved
    ///   - progress: Optional progress callback (completed count, total count)
    /// - Returns: Array of URLs to the generated mosaic files
    public func generateBatch(
        from videoURLs: [URL],
        config: MosaicConfiguration,
        outputDirectory: URL,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [URL] {
        logger.info("Generating mosaics for \(videoURLs.count) videos")

        var results: [URL] = []
        var completed = 0

        for videoURL in videoURLs {
            let mosaicURL = try await generate(
                from: videoURL,
                config: config,
                outputDirectory: outputDirectory
            )
            results.append(mosaicURL)

            completed += 1
            progress?(completed, videoURLs.count)
        }

        return results
    }
}

// Re-export key types for convenience
@_exported import struct CoreGraphics.CGSize
@_exported import struct CoreGraphics.CGFloat
