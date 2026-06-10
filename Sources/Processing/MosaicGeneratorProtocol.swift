import Foundation
import CoreImage

/// A protocol that defines the interface for video mosaic generators.
// @available(macOS 26, iOS 26, *)
public protocol MosaicGeneratorProtocol: Actor {
    /// Generates a mosaic for the specified video input and saves it to a file.
    ///
    /// - Parameters:
    ///   - video: The video input to process.
    ///   - config: The configuration settings for the mosaic generation.
    ///   - forIphone: A boolean value indicating whether to optimize the layout for iPhone screens.
    /// - Returns: The file `URL` where the generated mosaic image is saved.
    /// - Throws: An error if the mosaic generation or file writing fails.
    func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) async throws -> URL

    /// Generates a mosaic image directly in memory without saving to disk.
    ///
    /// - Parameters:
    ///   - video: The video input to process.
    ///   - config: The configuration settings for the mosaic generation.
    ///   - forIphone: A boolean value indicating whether to optimize the layout for iPhone screens.
    /// - Returns: The generated mosaic as a `CGImage`.
    /// - Throws: An error if the mosaic generation fails.
    func generateMosaicImage(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) async throws -> CGImage

    /// Generates mosaics for all predefined combinations of width sizes and density configurations.
    ///
    /// - Parameters:
    ///   - video: The video input to process.
    ///   - config: The base configuration settings for the mosaic generation.
    /// - Returns: An array of file `URL`s representing the generated mosaics.
    /// - Throws: An error if the mosaic generation fails for any combination.
    func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL]

    /// Cancels ongoing mosaic generation for the specified video.
    ///
    /// - Parameter video: The video to cancel mosaic generation for.
    func cancel(for video: VideoInput)

    /// Cancels all active and queued mosaic generation operations.
    func cancelAll()

    /// Sets a progress closure to monitor the mosaic generation progress of a specific video.
    ///
    /// - Parameters:
    ///   - video: The video input to monitor.
    ///   - handler: The progress closure called during different stages of generation.
    func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void)

    /// Returns performance metrics tracking generation times and task execution statistics.
    ///
    /// - Returns: A dictionary of performance metrics containing keys like `lastGenerationTime` and `totalGenerationTime`.
    func getPerformanceMetrics() -> [String: Any]
}
