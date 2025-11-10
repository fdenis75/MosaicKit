import Foundation

/// Protocol defining the interface for mosaic generators
@available(macOS 15, iOS 18, *)
public protocol MosaicGeneratorProtocol: Actor {
    /// Generate a mosaic for a video
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    ///   - forIphone: Whether to use iPhone-optimized layout
    /// - Returns: The URL of the generated mosaic image
    func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) async throws -> URL

    /// Generate mosaics for all combinations of sizes and densities
    /// - Parameters:
    ///   - video: The video to generate mosaics for
    ///   - config: Base configuration for mosaic generation
    /// - Returns: Array of URLs for generated mosaics
    func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL]

    /// Cancel mosaic generation for a specific video
    /// - Parameter video: The video to cancel mosaic generation for
    func cancel(for video: VideoInput)

    /// Cancel all ongoing mosaic generation operations
    func cancelAll()

    /// Set a progress handler for a specific video
    /// - Parameters:
    ///   - video: The video to set the progress handler for
    ///   - handler: The progress handler
    func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void)

    /// Get performance metrics for the mosaic generator
    /// - Returns: A dictionary of performance metrics
    func getPerformanceMetrics() -> [String: Any]
}
