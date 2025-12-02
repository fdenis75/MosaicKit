import Foundation
import AVFoundation
import CoreImage
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A Core Graphics-accelerated implementation for iOS mosaic generation
/// This implementation mirrors MetalMosaicGenerator but uses CoreGraphicsImageProcessor
@available(macOS 14, iOS 17, *)
public actor CoreGraphicsMosaicGenerator: MosaicGeneratorProtocol {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.mosaicKit", category: "cg-mosaic-generator")
    private let cgProcessor: CoreGraphicsImageProcessor
    private let layoutProcessor: LayoutProcessor
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "cg-mosaic-generator")

    private var generationTasks: [UUID: Task<URL, Error>] = [:]
    private var frameCache: [UUID: [CMTime: CGImage]] = [:]
    private var progressHandlers: [UUID: (MosaicGenerationProgress) -> Void] = [:]

    // Performance metrics
    private var lastGenerationTime: CFAbsoluteTime = 0
    private var totalGenerationTime: CFAbsoluteTime = 0
    private var generationCount: Int = 0
    private let thumbnailProcessor: ThumbnailProcessor

    // MARK: - Initialization

    /// Initialize a new Core Graphics mosaic generator for iOS
    /// - Parameter layoutProcessor: The layout processor to use
    public init(layoutProcessor: LayoutProcessor = LayoutProcessor()) throws {
        self.layoutProcessor = layoutProcessor
        self.thumbnailProcessor = ThumbnailProcessor(config: .default)
        do {
            self.cgProcessor = try CoreGraphicsImageProcessor()
            logger.debug("✅ Core Graphics mosaic generator initialized")
        } catch {
            logger.error("❌ Failed to initialize Core Graphics processor: \(error.localizedDescription)")
            throw error
        }
    }

    public func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL] {
        let sizes = [2000, 5000, 10000]
        let densities: [DensityConfig] = DensityConfig.allCases

        var mosaics: [URL] = []

        for size in sizes {
            for density in densities {
                let config = MosaicConfiguration(
                    width: size,
                    density: density,
                    format: .heif,
                    layout: .default,
                    includeMetadata: true,
                    useAccurateTimestamps: true,
                    compressionQuality: 0.4
                )
                let mosaic = try await generate(for: video, config: config)
                mosaics.append(mosaic)
            }
        }
        return mosaics
    }

    // MARK: - MosaicGenerating

    /// Generate a mosaic for a video using Core Graphics acceleration
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    ///   - forIphone: Whether to use iPhone-optimized layout
    /// - Returns: The URL of the generated mosaic image
    public func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false) async throws -> URL {
        logger.debug("🎯 Starting Core Graphics mosaic generation for video: \(video.title ?? "N/A")")

        let videoID = video.id

        if let existingTask = generationTasks[videoID] {
            logger.debug("⚡️ Reusing existing task for video: \(videoID.uuidString)")
            return try await existingTask.value
        }

        layoutProcessor.mosaicAspectRatio = config.layout.aspectRatio.ratio

        let task = Task<URL, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            defer { trackPerformance(startTime: startTime) }

            do {
                logger.debug("📊 \(video.title ?? "N/A") Video details - Duration: \(video.duration ?? 0.0)s, Size: \(video.fileSize ?? 0) bytes")

                let videoURL = video.url
                let asset = AVURLAsset(url: videoURL)
                let duration = video.duration ?? 9999.99
                let aspectRatio = (video.width ?? 1.0) / (video.height ?? 1.0)

                progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.2,
                    status: .countingThumbnails
                ))

                let frameCount = await layoutProcessor.calculateThumbnailCount(
                    duration: duration,
                    width: config.width,
                    density: config.density,
                    layoutType: forIphone ? .iphone : config.layout.layoutType,
                    videoAR: aspectRatio
                )
                logger.debug("🖼️ \(video.title ?? "N/A") - Calculated frame count: \(frameCount)")

                layoutProcessor.updateAspectRatio(config.layout.aspectRatio.ratio)

                // Calculate layout
                progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.3,
                    status: .computingLayout
                ))

                let layout = await layoutProcessor.calculateLayout(
                    originalAspectRatio: aspectRatio,
                    mosaicAspectRatio: config.layout.aspectRatio,
                    thumbnailCount: frameCount,
                    mosaicWidth: config.width,
                    density: config.density,
                    layoutType: forIphone ? .iphone : config.layout.layoutType
                )
                logger.debug("📏 \(video.title ?? "N/A") Layout calculated - Size: \(layout.mosaicSize.width)x\(layout.mosaicSize.height), Thumbnails: \(layout.thumbCount)")

                // Extract frames using ThumbnailProcessor
                let frames = try await thumbnailProcessor.extractThumbnails(
                    from: videoURL,
                    layout: layout,
                    asset: asset,
                    preview: false,
                    accurate: config.useAccurateTimestamps,
                    progressHandler: { @Sendable progress in
                        let scaledProgress = 0.4 + (0.3 * progress)
                        _ = MosaicGenerationProgress(
                            video: video,
                            progress: scaledProgress,
                            status: .extractingThumbnails
                        )
                    }
                )

                // Create metadata header if enabled
                var metadataHeader: CGImage? = nil
                if config.includeMetadata {
                    metadataHeader = thumbnailProcessor.createMetadataHeader(
                        for: video,
                        width: Int(layout.mosaicSize.width),
                        height: Int(layout.thumbnailSize.height * 0.5),
                        forIphone: forIphone
                    ) as CGImage?
                }

                // Generate mosaic using Core Graphics
                let mosaic = try await cgProcessor.generateMosaic(
                    from: frames,
                    layout: layout,
                    metadata: VideoMetadata(
                        codec: video.metadata.codec,
                        bitrate: video.metadata.bitrate,
                        custom: video.metadata.custom
                    ),
                    config: config,
                    metadataHeader: metadataHeader,
                    forIphone: forIphone,
                    progressHandler: { @Sendable progress in
                        let scaledProgress = 0.7 + (0.2 * progress)
                        _ = MosaicGenerationProgress(
                            video: video,
                            progress: scaledProgress,
                            status: .creatingMosaic
                        )
                    }
                )

                progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.9,
                    status: .savingMosaic
                ))

                // Save the mosaic to disk
                let mosaicURL = try await saveMosaic(
                    mosaic,
                    for: video,
                    config: config,
                    forIphone: forIphone
                )
                logger.debug("💾 Saved mosaic to: \(mosaicURL.path)")

                progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.999,
                    status: .savingMosaic
                ))

                return mosaicURL
            } catch {
                logger.error("❌ Core Graphics mosaic generation failed: \(error.localizedDescription)")
                throw error
            }
        }

        generationTasks[videoID] = task
        defer {
            generationTasks[videoID] = nil
            progressHandlers[videoID] = nil
        }

        return try await task.value
    }

    /// Cancel mosaic generation for a specific video
    /// - Parameter video: The video to cancel mosaic generation for
    public func cancel(for video: VideoInput) {
        logger.debug("❌ Cancelling Core Graphics mosaic generation for: \(video.title ?? "N/A")")
        generationTasks[video.id]?.cancel()
        generationTasks[video.id] = nil
        frameCache[video.id] = nil
    }

    /// Cancel all ongoing mosaic generation operations
    public func cancelAll() {
        logger.debug("❌ Cancelling all Core Graphics mosaic generation tasks")
        generationTasks.values.forEach { $0.cancel() }
        generationTasks.removeAll()
        frameCache.removeAll()
    }

    /// Set a progress handler for a specific video
    /// - Parameters:
    ///   - video: The video to set the progress handler for
    ///   - handler: The progress handler
    public func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void) {
        progressHandlers[video.id] = handler
    }

    /// Get performance metrics for the Core Graphics mosaic generator
    /// - Returns: A dictionary of performance metrics
    public func getPerformanceMetrics() -> [String: Any] {
        var metrics: [String: Any] = [
            "averageGenerationTime": generationCount > 0 ? totalGenerationTime / Double(generationCount) : 0,
            "totalGenerationTime": totalGenerationTime,
            "generationCount": generationCount,
            "lastGenerationTime": lastGenerationTime
        ]

        // Add Core Graphics processor metrics
        let cgMetrics = cgProcessor.getPerformanceMetrics()
        for (key, value) in cgMetrics {
            metrics["cg_\(key)"] = value
        }

        return metrics
    }

    // MARK: - Private Methods

    /// Format a timestamp in seconds to a string
    /// - Parameter seconds: The timestamp in seconds
    /// - Returns: A formatted timestamp string (HH:MM:SS)
    private func formatTimestamp(seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Save a mosaic image to disk
    /// - Parameters:
    ///   - mosaic: The mosaic image to save
    ///   - video: The video the mosaic was generated for
    ///   - config: The mosaic configuration
    ///   - forIphone: Whether this is an iPhone mosaic
    /// - Returns: The URL of the saved mosaic
    private func saveMosaic(
        _ mosaic: CGImage,
        for video: VideoInput,
        config: MosaicConfiguration,
        forIphone: Bool = false
    ) async throws -> URL {
        let state = signposter.beginInterval("Save Mosaic")
        defer { signposter.endInterval("Save Mosaic", state) }

        // Determine output directory based on configuration
        var baseOutputDirectory: URL
        var mosaicURL: URL!

        // Use structured output directory if metadata is available
        guard let rootFolder = config.outputdirectory else {
            logger.error("❌ No output directory specified in configuration")
            throw MosaicError.saveFailed(URL(fileURLWithPath: "/dev/null"),
                                        NSError(domain: "com.mosaickit", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: "Missing output directory"]))
        }

        // Generate structured path: {root}/{service}/{creator}/{configHash}/
        baseOutputDirectory = config.generateOutputDirectory(rootDirectory: rootFolder, videoInput: video)

        if baseOutputDirectory.startAccessingSecurityScopedResource() {
            defer { baseOutputDirectory.stopAccessingSecurityScopedResource() }
        }

        try FileManager.default.createDirectory(
            at: baseOutputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Generate filename using configuration method
        let videoURL = video.url
        let originalFilename = videoURL.deletingPathExtension().lastPathComponent
        let filename = config.generateFilename(originalFilename: originalFilename, videoInput: video)

        mosaicURL = baseOutputDirectory.appendingPathComponent(filename)

        logger.debug("💾 Saving mosaic to: \(mosaicURL.path)")

        // Check if file exists and handle overwrite
        if FileManager.default.fileExists(atPath: mosaicURL.path) {
            logger.debug("🔄 Overwriting existing file at: \(mosaicURL.path)")
            try FileManager.default.removeItem(at: mosaicURL)
        }

        // Convert CGImage to platform-specific image for saving
        #if canImport(AppKit)
        let platformImage = NSImage(cgImage: mosaic, size: .zero)
        #elseif canImport(UIKit)
        let platformImage = UIImage(cgImage: mosaic)
        #endif

        let data: Data?

        switch config.format {
        case .jpeg:
            data = getJpegData(from: platformImage, quality: config.compressionQuality)
            guard let imageData = data else {
                logger.error("❌ Failed to create image data")
                throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
            }

            try imageData.write(to: mosaicURL)
            logger.debug("✅ Mosaic saved successfully")
            logger.debug("📸 Saving as JPEG, quality: \(config.compressionQuality)")

        case .png:
            data = getPngData(from: platformImage)
            guard let imageData = data else {
                logger.error("❌ Failed to create image data")
                throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
            }

            try imageData.write(to: mosaicURL)
            logger.debug("✅ Mosaic saved successfully")
            logger.debug("📸 Saving as PNG")

        case .heif:
            if mosaicURL.deletingLastPathComponent().startAccessingSecurityScopedResource() {
                defer { mosaicURL.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
            }
            try await saveAsHEIC(mosaic, to: mosaicURL, quality: Float(config.compressionQuality))
            logger.debug("📸 Saving as HEIF, quality: \(config.compressionQuality)")
        }

        return mosaicURL
    }

    /// Track performance metrics
    /// - Parameter startTime: The start time of the operation
    private func trackPerformance(startTime: CFAbsoluteTime) {
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        lastGenerationTime = executionTime
        totalGenerationTime += executionTime
        generationCount += 1
    }

    /// Save image as HEIC format
    private func saveAsHEIC(_ image: CGImage, to url: URL, quality: Float) async throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            AVFileType.heic.rawValue as CFString,
            1,
            nil
        ) else {
            throw MosaicError.saveFailed(url, NSError(domain: "com.mosaicKit", code: -1))
        }

        let options: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImageDestinationEmbedThumbnail as String: true,
            kCGImagePropertyHasAlpha as String: false
        ]

        CGImageDestinationAddImage(destination, image, options as CFDictionary?)

        if !CGImageDestinationFinalize(destination) {
            throw MosaicError.saveFailed(url, NSError(domain: "com.mosaicKit", code: -1))
        }
    }
}

// MARK: - Extensions

#if canImport(AppKit)
private extension NSImage {
    func pngData() -> Data? {
        guard let tiffRepresentation = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: Double = 0.8) -> Data? {
        guard let tiffRepresentation = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .jpeg,
                                        properties: [.compressionFactor: compressionQuality])
    }
}
#endif

// Wrapper function to handle platform differences
private func getJpegData(from image: Any, quality: Double) -> Data? {
    #if canImport(AppKit)
    if let nsImage = image as? NSImage {
        return nsImage.jpegData(compressionQuality: quality)
    }
    #elseif canImport(UIKit)
    if let uiImage = image as? UIImage {
        return uiImage.jpegData(compressionQuality: CGFloat(quality))
    }
    #endif
    return nil
}

private func getPngData(from image: Any) -> Data? {
    #if canImport(AppKit)
    if let nsImage = image as? NSImage {
        return nsImage.pngData()
    }
    #elseif canImport(UIKit)
    if let uiImage = image as? UIImage {
        return uiImage.pngData()
    }
    #endif
    return nil
}
