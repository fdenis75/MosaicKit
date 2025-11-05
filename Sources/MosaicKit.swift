import Foundation
import Logging
import Metal

/// Main entry point for MosaicKit - Video Mosaic Generation Library
///
/// MosaicKit provides high-performance video mosaic generation using Metal acceleration.
///
/// ## Usage
///
/// ### Single Video
/// ```swift
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
/// ### Multiple Videos (Batch)
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
public final class MosaicGenerator {
    private let logger = Logger(label: "com.mosaickit")

    public init() throws {
        // Initialize Metal processor
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw MosaicError.metalNotSupported
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

        // Create VideoInput from URL
        let video = try await VideoInput(from: videoURL)

        // TODO: Call Metal mosaic generator
        // This requires adapting the MetalMosaicGenerator to work with VideoInput
        // and removing SwiftData dependencies

        throw MosaicError.processingFailed("Not yet implemented - see README.md")
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
