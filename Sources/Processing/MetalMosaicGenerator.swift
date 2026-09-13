import Foundation
import AVFoundation
import CoreImage
import OSLog
import Metal
import VideoToolbox
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Thread-safe accumulator for per-frame average colours used by the Color DNA strip.
private actor FrameColorCollector {
    private var colors: [Int: CGColor] = [:]

    func store(_ color: CGColor, at index: Int) {
        colors[index] = color
    }

    /// Returns colours sorted by frame index (temporal order), up to `count` entries.
    func orderedColors(count: Int) -> [CGColor] {
        (0..<count).compactMap { colors[$0] }
    }
}

/// A Metal-accelerated implementation of the MosaicGeneratorProtocol
public actor MetalMosaicGenerator: MosaicGeneratorProtocol {
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")
    private let metalProcessor: MetalImageProcessor
    private let layoutProcessor: LayoutProcessor
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")

    private var generationTasks: [UUID: [UUID: Task<URL, Error>]] = [:]
    private var imageGenerationTasks: [UUID: [UUID: Task<CGImage, Error>]] = [:]
    private var progressHandlerRevisions: [UUID: UUID] = [:]
    private var progressHandlers: [UUID: @Sendable (MosaicGenerationProgress) -> Void] = [:]
    
    // Performance metrics
    private var lastGenerationTime: CFAbsoluteTime = 0
    private var totalGenerationTime: CFAbsoluteTime = 0
    private var generationCount: Int = 0
    private let thumbnailProcessor: ThumbnailProcessor
    
    // MARK: - Initialization
    
    /// Initialize a new Metal-accelerated mosaic generator
    /// - Parameter layoutProcessor: The layout processor to use
    public init(layoutProcessor: LayoutProcessor = LayoutProcessor()) throws {
        self.layoutProcessor = layoutProcessor
        self.thumbnailProcessor = ThumbnailProcessor(config: .default)
        do {
            self.metalProcessor = try MetalImageProcessor()
        } catch {
            throw error
        }
    }
    
    public func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL] {
        let sizes = [2000,5000,10000]
        let densities: [DensityConfig] = DensityConfig.allCases
        
        var mosaics: [URL] = []
        
        for size in sizes {
            for density in densities {
                try Task.checkCancellation()
                let config = MosaicConfiguration(width: size, density: density, format: .heif, layout: .default, includeMetadata: true, useAccurateTimestamps: true, compressionQuality: 0.4)
                let mosaic = try await generate(for: video, config: config)
                mosaics.append(mosaic)
            }
        }
        return mosaics
    }
    
    // MARK: - MosaicGenerating
    

    /// Generate a mosaic for a video using Metal acceleration
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    /// - Returns: The URL of the generated mosaic image
    public func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false) async throws -> URL {
        try config.validate()
        let videoID = video.id

        try Task.checkCancellation()
        let attemptID = UUID()
        layoutProcessor.mosaicAspectRatio = config.layout.aspectRatio.ratio

        // Resolved once and reused for both the existence check below and the
        // actual save, so a `{time}` token in outputDirectoryTemplate can't
        // resolve to a different directory between the two (generation can
        // take many seconds).
        let referenceDate = Date()

        let attemptProgressHandler = progressHandlers[videoID]
        let handlerRevision = progressHandlerRevisions[videoID]
        let task = Task<URL, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            defer { trackPerformance(startTime: startTime) }

            try Task.checkCancellation()

            // Early-exit: if the output already exists and `overwrite` is false,
            // skip generation entirely and return the existing URL.
            if !config.overwrite {
                if config.gifMode == .gifOnly {
                    let animURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)
                    if FileManager.default.fileExists(atPath: animURL.path) {
                        logger.debug("⏭️ Animation already exists, skipping generation: \(animURL.path)")
                        return animURL
                    }
                } else {
                    let rootFolder = config.outputdirectory ?? video.url.deletingLastPathComponent()
                    let outputDir = config.generateOutputDirectory(rootDirectory: rootFolder, videoInput: video, referenceDate: referenceDate)
                    let originalFilename = video.url.deletingPathExtension().lastPathComponent
                    let filename = config.generateFilename(originalFilename: originalFilename, videoInput: video)
                    let mosaicURL = outputDir.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: mosaicURL.path) {
                        if config.gifMode == .withMosaic {
                            let animationURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)
                            if !FileManager.default.fileExists(atPath: animationURL.path) {
                                let asset = AVURLAsset(url: video.url)
                                let duration = try await asset.load(.duration).seconds
                                guard duration.isFinite, duration > 0 else { throw MosaicError.invalidVideo("Invalid duration") }
                                let ratio = (video.width ?? 1) / (video.height ?? 1)
                                let count = layoutProcessor.calculateThumbnailCount(duration: duration, width: config.width,
                                    density: config.density, layoutType: forIphone ? .iphone : config.layout.layoutType, videoAR: ratio)
                                let layout = layoutProcessor.calculateLayout(originalAspectRatio: ratio,
                                    mosaicAspectRatio: config.layout.aspectRatio, thumbnailCount: count, mosaicWidth: config.width,
                                    density: config.density, layoutType: forIphone ? .iphone : config.layout.layoutType)
                                let frames = try await thumbnailProcessor.extractFramesForGif(from: video.url, asset: asset,
                                    count: layout.thumbCount, gifSize: config.gifSize, accurate: config.useAccurateTimestamps)
                                try AnimatedGifGenerator.save(frames: frames, to: animationURL, format: config.animatedFormat,
                                    frameDelay: 1.0 / config.gifFps, overwrite: false)
                            }
                        }
                        return mosaicURL
                    }
                }
            }
    
            do {
                let videoURL = video.url

                // Get video duration and calculate frame count
                let asset = AVURLAsset(url: videoURL) // Use unwrapped URL
                /*
                let duration = try await asset.load(.duration).seconds
                let aspectRatio = try await calculateAspectRatio(from: asset)
                */
                let duration: Double
                if let known = video.duration { duration = known } else { duration = try await asset.load(.duration).seconds }
                guard duration.isFinite, duration > 0, config.width > 0, config.width <= 16_384, (video.width ?? 1).isFinite, (video.height ?? 1).isFinite, (video.width ?? 1) > 0, (video.height ?? 1) > 0 else { throw MosaicError.invalidVideo("Invalid duration or dimensions") }
                if duration < 5.0 {
                    throw MosaicError.invalidVideo("video too short")
                }
                let aspectRatio = (video.width ?? 1.0) / (video.height ?? 1.0)
                attemptProgressHandler?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.00,
                    status: .countingThumbnails
                ))
                let frameCount =  layoutProcessor.calculateThumbnailCount(
                    duration: duration,
                    width: config.width,
                    density: config.density,
                    layoutType: forIphone ? .iphone : config.layout.layoutType,
                    videoAR: aspectRatio
                )
                // Calculate layout
                attemptProgressHandler?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.00,
                    status: .computingLayout
                ))
                let layout =  layoutProcessor.calculateLayout(
                    originalAspectRatio: aspectRatio,
                    mosaicAspectRatio: config.layout.aspectRatio,
                    thumbnailCount: frameCount,
                    mosaicWidth: config.width,
                    density: config.density,
                    layoutType: forIphone ? .iphone : config.layout.layoutType
                )
                logger.debug("📐 Generation plan for \(video.title) - width: \(config.width), density: \(config.density.name), requested frames: \(frameCount), layout positions: \(layout.positions.count), mosaic size: \(Int(layout.mosaicSize.width))x\(Int(layout.mosaicSize.height))")

                // MARK: - FIX: Create a mutable copy of config and use the static method
                var mutableConfig = config // Create a mutable copy
                mutableConfig.updateAspectRatio(new: AspectRatio.findNearest(to: layout.mosaicSize)) // Call on mutable copy using static method

                let layoutTime = CFAbsoluteTimeGetCurrent()
                let executionTime = layoutTime - startTime
                logger.debug("layout process in \(executionTime) seconds")

                // Animation-only mode: skip mosaic entirely
                if mutableConfig.gifMode == .gifOnly {
                    let animURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)
                    try FileManager.default.createDirectory(
                        at: animURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    let gifFrames = try await thumbnailProcessor.extractFramesForGif(
                        from: videoURL,
                        asset: asset,
                        count: layout.thumbCount,
                        gifSize: mutableConfig.gifSize,
                        accurate: mutableConfig.useAccurateTimestamps
                    )
                    try AnimatedGifGenerator.save(frames: gifFrames, to: animURL, format: mutableConfig.animatedFormat, frameDelay: 1.0 / mutableConfig.gifFps, overwrite: mutableConfig.overwrite)
                    logger.debug("💾 Animation-only saved to: \(animURL.path)")
                    return animURL
                }

                // Extract frames using VideoToolbox for hardware acceleration
       /*         attemptProgressHandler?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.4,
                    status: .extractingThumbnails
                ))
               // attemptProgressHandler? (0.1) // Use unwrapped ID
                /*let frames = try await extractFramesWithVideoToolbox(
                    from: asset,
                    count: layout.thumbCount,
                    accurate: config.useAccurateTimestamps
                )*/*/
                // Capture progress handler before passing to async context
                let currentProgressHandler = attemptProgressHandler

                let overlayConfig = mutableConfig.overlay

                // If metadata is enabled, create a header image with enhanced information
                var metadataHeader: CGImage? = nil
                if mutableConfig.includeMetadata {
                    metadataHeader = thumbnailProcessor.createMetadataHeader(
                        for: video,
                        width: Int(layout.mosaicSize.width),
                        thumbnailHeight: layout.thumbnailSize.height,
                        forIphone: forIphone,
                        headerConfig: overlayConfig.header
                    ) as CGImage?
                }

                let colorCollector = overlayConfig.colorDNA.show ? FrameColorCollector() : nil
                let processedStream = thumbnailProcessor.processedFramesStream(
                    from: videoURL, layout: layout, asset: asset,
                    accurate: mutableConfig.useAccurateTimestamps,
                    labelConfig: overlayConfig.frameLabel,
                    collectColor: { index, image in
                        if let collector = colorCollector {
                            await collector.store(OverlayProcessor.averageColor(of: image), at: index)
                        }
                    }
                )
                
                // Generate mosaic using Metal with streaming input
                var mosaic = try await metalProcessor.generateMosaicStream(
                    stream: processedStream,
                    layout: layout,
                    metadata: VideoMetadata(
                        codec: video.metadata.codec,
                        bitrate: video.metadata.bitrate,
                        custom: video.metadata.custom
                    ),
                    config: mutableConfig,
                    metadataHeader: metadataHeader,
                    forIphone: forIphone,
                    progressHandler: { @Sendable progress in
                        let scaledProgress = 0.7 + (0.299 * progress)
                        currentProgressHandler?(MosaicGenerationProgress(
                            video: video,
                            progress: scaledProgress,
                            status: .creatingMosaic
                        ))
                    }
                )

                // Apply Color DNA strip
                if overlayConfig.colorDNA.show, let collector = colorCollector {
                    let frameColors = await collector.orderedColors(count: layout.thumbCount)
                    if let dnaImage = OverlayProcessor.applyColorDNA(
                        to: mosaic, frameColors: frameColors, config: overlayConfig.colorDNA) {
                        mosaic = dnaImage
                    }
                }

                // Apply watermark
                if let wmConfig = overlayConfig.watermark,
                   let watermarked = OverlayProcessor.applyWatermark(to: mosaic, config: wmConfig) {
                    mosaic = watermarked
                }

                attemptProgressHandler?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.9,
                    status: .savingMosaic
                ))
                // Save the mosaic to disk
                let mosaicURL = try await saveMosaic(
                    mosaic,
                    for: video,
                    config: config,
                    forIphone: forIphone,
                    referenceDate: referenceDate
                )

                attemptProgressHandler?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.999,
                    status: .savingMosaic
                ))

                // Generate animated image alongside the mosaic when requested
                if mutableConfig.gifMode == .withMosaic {
                    let animURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)

                    if FileManager.default.fileExists(atPath: animURL.path) && !mutableConfig.overwrite {
                        logger.debug("⏭️ Animation already exists, skipping animation save: \(animURL.path)")
                    } else {
                        let gifFrames = try await thumbnailProcessor.extractFramesForGif(
                            from: videoURL,
                            asset: asset,
                            count: layout.thumbCount,
                            gifSize: mutableConfig.gifSize,
                            accurate: mutableConfig.useAccurateTimestamps
                        )
                        try AnimatedGifGenerator.save(frames: gifFrames, to: animURL, format: mutableConfig.animatedFormat, frameDelay: 1.0 / mutableConfig.gifFps, overwrite: mutableConfig.overwrite)
                        logger.debug("💾 Animation saved to: \(animURL.path)")
                    }
                }

                return mosaicURL
            } catch {
                throw error
            }
        }

        generationTasks[videoID, default: [:]][attemptID] = task
        defer {
            generationTasks[videoID]?[attemptID] = nil
            if generationTasks[videoID]?.isEmpty == true { generationTasks[videoID] = nil }
            releaseProgressHandler(videoID: videoID, revision: handlerRevision)
        }

        // Bridge caller cancellation into the internal task: without this,
        // cancelling the awaiting task (e.g. a coordinator wrapper) would leave
        // the generation running to completion in the background.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Generate a mosaic image for a video without saving to disk
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    ///   - forIphone: Whether to use iPhone-optimized layout
    /// - Returns: The generated mosaic as a CGImage
    public func generateMosaicImage(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false) async throws -> CGImage {
        try config.validate()
        let videoID = video.id
        let attemptID = UUID()
        layoutProcessor.mosaicAspectRatio = config.layout.aspectRatio.ratio

        // Run the generation in a tracked task so cancel(for:) / cancelAll() reach
        // in-memory image generation the same way they reach file generation.
        let attemptProgressHandler = progressHandlers[videoID]
        let handlerRevision = progressHandlerRevisions[videoID]
        let task = Task<CGImage, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            defer { trackPerformance(startTime: startTime) }
            try Task.checkCancellation()
            return try await performMosaicImageGeneration(for: video, config: config, forIphone: forIphone, attemptProgressHandler: attemptProgressHandler)
        }

        imageGenerationTasks[videoID, default: [:]][attemptID] = task
        defer {
            imageGenerationTasks[videoID]?[attemptID] = nil
            if imageGenerationTasks[videoID]?.isEmpty == true { imageGenerationTasks[videoID] = nil }
            releaseProgressHandler(videoID: videoID, revision: handlerRevision)
        }

        // Bridge caller cancellation into the tracked task (see generate(for:config:forIphone:)).
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Body of `generateMosaicImage(for:config:forIphone:)` — runs inside the tracked task.
    private func performMosaicImageGeneration(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool, attemptProgressHandler: (@Sendable (MosaicGenerationProgress) -> Void)?) async throws -> CGImage {
        do {
            let videoURL = video.url
            let asset = AVURLAsset(url: videoURL)
            let duration: Double
                if let known = video.duration { duration = known } else { duration = try await asset.load(.duration).seconds }
                guard duration.isFinite, duration > 0, config.width > 0, config.width <= 16_384, (video.width ?? 1).isFinite, (video.height ?? 1).isFinite, (video.width ?? 1) > 0, (video.height ?? 1) > 0 else { throw MosaicError.invalidVideo("Invalid duration or dimensions") }

            if duration < 5.0 {
                throw MosaicError.invalidVideo("video too short")
            }

            let aspectRatio = (video.width ?? 1.0) / (video.height ?? 1.0)

            attemptProgressHandler?(MosaicGenerationProgress(
                video: video,
                progress: 0.00,
                status: .countingThumbnails
            ))

            let frameCount = layoutProcessor.calculateThumbnailCount(
                duration: duration,
                width: config.width,
                density: config.density,
                layoutType: forIphone ? .iphone : config.layout.layoutType,
                videoAR: aspectRatio
            )


            attemptProgressHandler?(MosaicGenerationProgress(
                video: video,
                progress: 0.00,
                status: .computingLayout
            ))

            let layout = layoutProcessor.calculateLayout(
                originalAspectRatio: aspectRatio,
                mosaicAspectRatio: config.layout.aspectRatio,
                thumbnailCount: frameCount,
                mosaicWidth: config.width,
                density: config.density,
                layoutType: forIphone ? .iphone : config.layout.layoutType
            )

            var mutableConfig = config
            mutableConfig.updateAspectRatio(new: AspectRatio.findNearest(to: layout.mosaicSize))

            let currentProgressHandler = attemptProgressHandler

            let overlayConfig = mutableConfig.overlay

            // Create metadata header if enabled
            var metadataHeader: CGImage? = nil
            if mutableConfig.includeMetadata {
                metadataHeader = thumbnailProcessor.createMetadataHeader(
                    for: video,
                    width: Int(layout.mosaicSize.width),
                    thumbnailHeight: layout.thumbnailSize.height,
                    forIphone: forIphone,
                    headerConfig: overlayConfig.header
                ) as CGImage?
            }

            let colorCollector = overlayConfig.colorDNA.show ? FrameColorCollector() : nil
            let processedStream = thumbnailProcessor.processedFramesStream(
                from: videoURL, layout: layout, asset: asset,
                accurate: mutableConfig.useAccurateTimestamps,
                labelConfig: overlayConfig.frameLabel,
                collectColor: { index, image in
                    if let collector = colorCollector {
                        await collector.store(OverlayProcessor.averageColor(of: image), at: index)
                    }
                }
            )
            
            // Generate mosaic using Metal with streaming input
            var mosaic = try await metalProcessor.generateMosaicStream(
                stream: processedStream,
                layout: layout,
                metadata: VideoMetadata(
                    codec: video.metadata.codec,
                    bitrate: video.metadata.bitrate,
                    custom: video.metadata.custom
                ),
                config: mutableConfig,
                metadataHeader: metadataHeader,
                forIphone: forIphone,
                progressHandler: { @Sendable progress in
                    let scaledProgress = 0.7 + (0.299 * progress)
                    currentProgressHandler?(MosaicGenerationProgress(
                        video: video,
                        progress: scaledProgress,
                        status: .creatingMosaic
                    ))
                }
            )

            // Apply Color DNA strip
            if overlayConfig.colorDNA.show, let collector = colorCollector {
                let frameColors = await collector.orderedColors(count: layout.thumbCount)
                if let dnaImage = OverlayProcessor.applyColorDNA(
                    to: mosaic, frameColors: frameColors, config: overlayConfig.colorDNA) {
                    mosaic = dnaImage
                }
            }

            // Apply watermark
            if let wmConfig = overlayConfig.watermark,
               let watermarked = OverlayProcessor.applyWatermark(to: mosaic, config: wmConfig) {
                mosaic = watermarked
            }

            attemptProgressHandler?(MosaicGenerationProgress(
                video: video,
                progress: 1.0,
                status: .completed
            ))

            try Task.checkCancellation()
            return mosaic
        } catch {
            throw error
        }
    }

    private func releaseProgressHandler(videoID: UUID, revision: UUID?) {
        guard generationTasks[videoID] == nil, imageGenerationTasks[videoID] == nil,
              progressHandlerRevisions[videoID] == revision else { return }
        progressHandlers[videoID] = nil
        progressHandlerRevisions[videoID] = nil
    }

    /// Cancel mosaic generation for a specific video
    /// - Parameter video: The video to cancel mosaic generation for
    public func cancel(for video: VideoInput) {
        generationTasks[video.id]?.values.forEach { $0.cancel() }
        generationTasks[video.id] = nil
        imageGenerationTasks[video.id]?.values.forEach { $0.cancel() }
        imageGenerationTasks[video.id] = nil
    }

    /// Cancel all ongoing mosaic generation operations
    public func cancelAll() {
        generationTasks.values.forEach { $0.values.forEach { $0.cancel() } }
        generationTasks.removeAll()
        imageGenerationTasks.values.forEach { $0.values.forEach { $0.cancel() } }
        imageGenerationTasks.removeAll()
    }
    
    /// Set a progress handler for a specific video
    /// - Parameters:
    ///   - video: The video to set the progress handler for
    ///   - handler: The progress handler
    public func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void) {
             progressHandlerRevisions[video.id] = UUID()
             progressHandlers[video.id] = handler
        }
    
    
    /// Get performance metrics for the Metal mosaic generator
    /// - Returns: A dictionary of performance metrics
    public func getPerformanceMetrics() -> [String: Any] {
        var metrics: [String: Any] = [
            "averageGenerationTime": generationCount > 0 ? totalGenerationTime / Double(generationCount) : 0,
            "totalGenerationTime": totalGenerationTime,
            "generationCount": generationCount,
            "lastGenerationTime": lastGenerationTime
        ]
        
        // Add Metal processor metrics
        let metalMetrics = metalProcessor.getPerformanceMetrics()
        for (key, value) in metalMetrics {
            metrics["metal_\(key)"] = value
        }
        
        return metrics
    }
    
    // MARK: - Private Methods
    
    /// Extract frames from a video using VideoToolbox for hardware acceleration
    /// - Parameters:
    ///   - asset: The video asset to extract frames from
    ///   - count: The number of frames to extract
    ///   - accurate: Whether to use accurate timestamp extraction
    /// - Returns: Array of tuples containing frame images and their timestamps
    private func extractFramesWithVideoToolbox(
        from asset: AVAsset,
        count: Int,
        accurate: Bool
    ) async throws -> [(image: CGImage, timestamp: String)] {
        let state = signposter.beginInterval("Extract Frames VideoToolbox")
        defer { signposter.endInterval("Extract Frames VideoToolbox", state) }

        let duration = try await asset.load(.duration).seconds
        
        let times = calculateExtractionTimes(duration: duration, count: count)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        // Optimize for hardware decoding
        generator.requestedTimeToleranceAfter = accurate ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = accurate ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        
        var collected: [(Int, CGImage, String)] = []

        var currentIndex = 0
        for await result in generator.images(for: times) {
            if Task.isCancelled {
                throw CancellationError()
            }

            let index = currentIndex
            currentIndex += 1

            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actualTime):
                let timestamp = formatTimestamp(seconds: actualTime.seconds)
                collected.append((index, image, timestamp))
            case .failure(requestedTime: _, error: let error):
                throw error
            }
        }
        
        return collected.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }
    
    /// Calculate evenly distributed extraction times for a video
    /// - Parameters:
    ///   - duration: The duration of the video in seconds
    ///   - count: The number of frames to extract
    /// - Returns: Array of CMTime values for frame extraction
    private func calculateExtractionTimes(duration: Double, count: Int) -> [CMTime] {
        let startPoint = duration * 0.05
        let endPoint = duration * 0.95
        let effectiveDuration = endPoint - startPoint
        
        let firstThirdCount = Int(Double(count) * 0.2)
        let middleCount = Int(Double(count) * 0.6)
        let lastThirdCount = count - firstThirdCount - middleCount
        
        let firstThirdEnd = startPoint + effectiveDuration * 0.33
        let lastThirdStart = startPoint + effectiveDuration * 0.67
        
        let firstThirdStep = (firstThirdEnd - startPoint) / Double(firstThirdCount)
        let middleStep = (lastThirdStart - firstThirdEnd) / Double(middleCount)
        let lastThirdStep = (endPoint - lastThirdStart) / Double(lastThirdCount)
        
        let firstThirdTimes = (0..<firstThirdCount).map { index in
            CMTime(seconds: startPoint + Double(index) * firstThirdStep, preferredTimescale: 600)
        }
        
        let middleTimes = (0..<middleCount).map { index in
            CMTime(seconds: firstThirdEnd + Double(index) * middleStep, preferredTimescale: 600)
        }
        
        let lastThirdTimes = (0..<lastThirdCount).map { index in
            CMTime(seconds: lastThirdStart + Double(index) * lastThirdStep, preferredTimescale: 600)
        }
        
        return firstThirdTimes + middleTimes + lastThirdTimes
    }
    
    /// Format a timestamp in seconds to a string
    /// - Parameter seconds: The timestamp in seconds
    /// - Returns: A formatted timestamp string (HH:MM:SS)
    private func formatTimestamp(seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    /// Calculate the aspect ratio of a video
    /// - Parameter asset: The video asset
    /// - Returns: The aspect ratio (width / height)
    private func calculateAspectRatio(from asset: AVAsset) async throws -> CGFloat {
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize) ?? CGSize(width: 16, height: 9)
        let transform = try await track?.load(.preferredTransform) ?? .identity
        let videoSize = size.applying(transform)
        let ratio = abs(videoSize.width / videoSize.height)
        return ratio
    }
    
    /// Save a mosaic image to disk
    /// - Parameters:
    ///   - mosaic: The mosaic image to save
    ///   - video: The video the mosaic was generated for
    ///   - config: The mosaic configuration
    ///   - referenceDate: The date/time used to resolve `{date}`/`{time}` tokens
    ///     in `config.outputDirectoryTemplate`. Callers should pass the same
    ///     `referenceDate` used for any earlier existence check on this same
    ///     save operation so a `{time}` token resolves to the same directory.
    /// - Returns: The URL of the saved mosaic
    private func saveMosaic(
        _ mosaic: CGImage,
        for video: VideoInput,
        config: MosaicConfiguration,
        forIphone: Bool = false,
        referenceDate: Date = Date()
    ) async throws -> URL {
        let state = signposter.beginInterval("Save Mosaic")
        defer { signposter.endInterval("Save Mosaic", state) }
        signposter.emitEvent("saving mosaic","name : \(video.url.lastPathComponent)")

        // Determine base output directory
        var baseOutputDirectory: URL
        var mosaicURL: URL!

        // Use the video's folder when no explicit output directory is configured.
        let rootFolder = config.outputdirectory ?? video.url.deletingLastPathComponent()

        // Generate structured path: {root}/{service}/{creator}/{configHash}/
        baseOutputDirectory = config.generateOutputDirectory(rootDirectory: rootFolder, videoInput: video, referenceDate: referenceDate)

        let didStartAccessingBaseDirectory = baseOutputDirectory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingBaseDirectory {
                baseOutputDirectory.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: baseOutputDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)

        // Generate filename using configuration method
        let videoURL = video.url
        let originalFilename = videoURL.deletingPathExtension().lastPathComponent
        let filename = config.generateFilename(originalFilename: originalFilename, videoInput: video)

        mosaicURL = baseOutputDirectory.appendingPathComponent(filename)

        let transaction = try OutputTransaction(finalURL: mosaicURL, overwrite: config.overwrite)
        defer { transaction.discard() }
        try Task.checkCancellation()
        
        if config.format == .webp {
            let didStartAccessingDirectory = mosaicURL.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer {
                if didStartAccessingDirectory {
                    mosaicURL.deletingLastPathComponent().stopAccessingSecurityScopedResource()
                }
            }
            guard let encoder = MosaicKitWebPSupport.encoder else {
                throw MosaicKitWebPError.encoderNotRegistered
            }
            let data = try encoder.encodeStillWebP(mosaic, quality: Float(config.compressionQuality * 100))
            try data.write(to: transaction.stagingURL)
            try transaction.commit()
            return mosaicURL
        }

        let identifier: CFString
        switch config.format {
        case .jpeg:
            identifier = UTType.jpeg.identifier as CFString
        case .png:
            identifier = UTType.png.identifier as CFString
        case .heif:
            identifier = UTType.heic.identifier as CFString
        case .webp:
            identifier = UTType.webP.identifier as CFString
        }

        // Use security scoped resource for HEIF
        var didStartAccessingDirectory = false
        if config.format == .heif {
            let directory = mosaicURL.deletingLastPathComponent()
            didStartAccessingDirectory = directory.startAccessingSecurityScopedResource()
        }
        defer {
            if didStartAccessingDirectory {
                mosaicURL.deletingLastPathComponent().stopAccessingSecurityScopedResource()
            }
        }

        guard let destination = CGImageDestinationCreateWithURL(
            transaction.stagingURL as CFURL,
            identifier,
            1,
            nil
        ) else {
            throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
        }

        var options: [String: Any] = [:]
        if config.format == .jpeg || config.format == .heif {
            options[kCGImageDestinationLossyCompressionQuality as String] = config.compressionQuality
        }
        if config.format == .heif {
            options[kCGImageDestinationEmbedThumbnail as String] = true
            options[kCGImagePropertyHasAlpha as String] = false
        }

        CGImageDestinationAddImage(destination, mosaic, options as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
        }

        try transaction.commit()
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
}
