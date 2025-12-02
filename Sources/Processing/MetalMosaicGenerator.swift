import Foundation
import AVFoundation
import CoreImage
import OSLog
import Metal
import VideoToolbox
// Explicitly import the Error type if it's from the main app module
// Assuming HyperMovieModels is part of the main app or another accessible module
//@preconcurrency import enum HyperMovieModels.MosaicError
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Define a platform-specific image type if not already defined
#if canImport(AppKit)
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
typealias PlatformImage = UIImage
#endif

/// A Metal-accelerated implementation of the MosaicGeneratorProtocol
//@available(macOS )
public actor MetalMosaicGenerator: MosaicGeneratorProtocol {
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")
    private let metalProcessor: MetalImageProcessor
    private let layoutProcessor: LayoutProcessor
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")

    private var generationTasks: [UUID: Task<URL, Error>] = [:]
    private var frameCache: [UUID: [CMTime: CGImage]] = [:]
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
            // logger.debug("✅ Metal mosaic generator initialized with Metal processor")
        } catch {
            // logger.error("❌ Failed to initialize Metal processor: \(error.localizedDescription)")
            throw error
        }
    }
    
    public func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL] {
        let sizes = [2000,5000,10000]
        let densities: [DensityConfig] = DensityConfig.allCases
        
        var mosaics: [URL] = []
        
        for size in sizes {
            for density in densities {
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
        // Provide default value for optional title
        // logger.debug("🎯 Starting Metal-accelerated mosaic generation for video: \(video.title ?? "N/A")")
        
        // Safely unwrap video.id
         let videoID = video.id 

        if let existingTask = generationTasks[videoID] {
            // logger.debug("⚡️ Reusing existing task for video: \(videoID.uuidString)")
            return try await existingTask.value
        }
        layoutProcessor.mosaicAspectRatio = config.layout.aspectRatio.ratio
        let task = Task<URL, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            defer { trackPerformance(startTime: startTime) }
            
            do {
                // Provide default values for optional title and duration
                // logger.debug("📊 \(video.title ?? "N/A") Video details - Duration: \(video.duration ?? 0.0)s, Size: \(video.fileSize ?? 0) bytes")
                
                // Safely unwrap video.url
               let videoURL = video.url
            // Or a more specific error
                 //   throw MosaicError.inputNotFound // Or a more specific error
                
                
                // Get video duration and calculate frame count
                let asset = AVURLAsset(url: videoURL) // Use unwrapped URL
                /*
                let duration = try await asset.load(.duration).seconds
                let aspectRatio = try await calculateAspectRatio(from: asset)
              //  // logger.debug("📐 Video aspect ratio: \(aspectRatio)")*/
                let duration = video.duration ?? 9999.99
                if duration < 5.0 {
                    throw MosaicError.invalidVideo("video too short")
                }
                let aspectRatio = (video.width ?? 1.0) / (video.height ?? 1.0)
                progressHandlers[videoID]?(MosaicGenerationProgress(
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
                // logger.debug("🖼️ \(video.title ?? "N/A") - Calculated frame count: \(frameCount)")
                layoutProcessor.updateAspectRatio(config.layout.aspectRatio.ratio)
                // Calculate layout
                progressHandlers[videoID]?(MosaicGenerationProgress(
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
                
                // MARK: - FIX: Create a mutable copy of config and use the static method
                var mutableConfig = config // Create a mutable copy
                mutableConfig.updateAspectRatio(new: AspectRatio.findNearest(to: layout.mosaicSize)) // Call on mutable copy using static method
                
                let layoutTime = CFAbsoluteTimeGetCurrent()
                let executionTime = layoutTime - startTime
                print("layout process in \(executionTime) seconds")
                // logger.debug("📏 \(video.title ?? "N/A") Layout calculated - Size: \(layout.mosaicSize.width)x\(layout.mosaicSize.height), Thumbnails: \(layout.thumbCount)")
                
                // Extract frames using VideoToolbox for hardware acceleration
       /*         progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.4,
                    status: .extractingThumbnails
                ))
               // progressHandlers[videoID]? (0.1) // Use unwrapped ID
                /*let frames = try await extractFramesWithVideoToolbox(
                    from: asset,
                    count: layout.thumbCount,
                    accurate: config.useAccurateTimestamps
                )*/*/
                // Capture progress handler before passing to async context
                let currentProgressHandler = progressHandlers[videoID]

                // If metadata is enabled, create a header image with enhanced information
                var metadataHeader: CGImage? = nil
                if mutableConfig.includeMetadata { // Use mutableConfig
                 //   // logger.debug("🏷️ Creating enhanced metadata header with complete video information")
                    metadataHeader = thumbnailProcessor.createMetadataHeader(
                        for: video,
                        width: Int(layout.mosaicSize.width),
                        height: Int(layout.thumbnailSize.height * 0.5),
                        forIphone: forIphone
                    ) as CGImage? // Use as? for safe casting
                }

                // Create a stream for processed images (with timestamps)
                let (processedStream, continuation) = AsyncThrowingStream<(Int, CGImage), Error>.makeStream()
                
                // Capture dependencies for the producer task
                let processor = self.thumbnailProcessor
                let thumbnailSizes = layout.thumbnailSizes
                
                // Start producer task to burn timestamps in parallel
                Task {
                    do {
                        let rawStream = processor.extractFramesStream(
                            from: videoURL,
                            layout: layout,
                            asset: asset,
                            accurate: mutableConfig.useAccurateTimestamps // Use mutableConfig
                        )
                        
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            for try await (index, rawImage, timestamp) in rawStream {
                                group.addTask {
                                    let size = thumbnailSizes[index]
                                    let processedImage = processor.addTimestampToImage(
                                        image: rawImage,
                                        timestamp: timestamp,
                                        size: size
                                    )
                                    continuation.yield((index, processedImage))
                                }
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                // Generate mosaic using Metal with streaming input
                let mosaic = try await metalProcessor.generateMosaicStream(
                    stream: processedStream,
                    layout: layout,
                    metadata: VideoMetadata(
                        codec: video.metadata.codec,
                        bitrate: video.metadata.bitrate,
                        custom: video.metadata.custom
                    ),
                    config: mutableConfig, // Use mutableConfig
                    metadataHeader: metadataHeader,
                    forIphone: forIphone,
                    progressHandler: { @Sendable progress in
                        // Scale the progress to fit within the overall progress range (0.5-0.8)
                        let scaledProgress = 0.7 + (0.299 * progress)
                        currentProgressHandler?(MosaicGenerationProgress(
                            video: video,
                            progress: scaledProgress,
                            status: .creatingMosaic
                        ))
                    }
                )
               // // logger.debug("🖼️ Metal mosaic created - Size: \(mosaic.width)x\(mosaic.height)")
                
                progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.9,
                    status: .savingMosaic
                ))
                // Save the mosaic to disk
                let mosaicURL = try await saveMosaic(
                    mosaic,
                    for: video,
                    config: mutableConfig, // Use mutableConfig
                    forIphone:  forIphone
                )
                
                // logger.debug("💾 Saved mosaic to: \(mosaicURL.path)")
                
                progressHandlers[videoID]?(MosaicGenerationProgress(
                    video: video,
                    progress: 0.999,
                    status: .savingMosaic
                ))
                
             //   await MainActor.run {
               //     video.mosaicURL = mosaicURL.absoluteString
                //}
                
                return mosaicURL
            } catch {
                // logger.error("❌ Metal mosaic generation failed: \(error.localizedDescription)")
                throw error
            }
        }
        
        generationTasks[videoID] = task // Use unwrapped ID
        defer {
            generationTasks[videoID] = nil // Use unwrapped ID
            progressHandlers[videoID] = nil // Use unwrapped ID
        }
        
        return try await task.value
    }
    
    /// Cancel mosaic generation for a specific video
    /// - Parameter video: The video to cancel mosaic generation for
    public func cancel(for video: VideoInput) {
        // Provide default value for optional title
        // logger.debug("❌ Cancelling Metal mosaic generation for: \(video.title ?? "N/A")")
     
        generationTasks[video.id]?.cancel()
            generationTasks[video.id] = nil
            frameCache[video.id] = nil
        
    }
    
    /// Cancel all ongoing mosaic generation operations
    public func cancelAll() {
        // logger.debug("❌ Cancelling all Metal mosaic generation tasks")
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
        let startTime = CFAbsoluteTimeGetCurrent()
        // logger.debug("🎬 Starting VideoToolbox frame extraction - Count: \(count)")
        
        let duration = try await asset.load(.duration).seconds
        
        let times = calculateExtractionTimes(duration: duration, count: count)

        // Dynamically adjust concurrency based on system capabilities
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let concurrencyLimit = min(max(processorCount - 1, 4), 16) // At least 4, at most 16
        // logger.debug("⚙️ Using concurrency limit of \(concurrencyLimit) based on \(processorCount) available processors")
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        // Optimize for hardware decoding
        generator.requestedTimeToleranceAfter = accurate ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = accurate ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        
        // We'll maintain at most `concurrencyLimit` child tasks in-flight without blocking.
        var inFlight: [Task<(Int, CGImage, String), Error>] = []
        var nextIndexToStart = 0
        var completed = 0
        let totalFrames = times.count
        let progressInterval = max(1, totalFrames / 10)
        var collected: [(Int, CGImage, String)] = []
        
        func startNextIfPossible() {
            while nextIndexToStart < totalFrames && inFlight.count < concurrencyLimit {
                let index = nextIndexToStart
                let time = times[index]
                nextIndexToStart += 1
                let t = Task<(Int, CGImage, String), Error> {
                    if Task.isCancelled { throw CancellationError() }
                    let imageRef = try await generator.image(at: time)
                    let ts = await self.formatTimestamp(seconds: imageRef.actualTime.seconds)
                    return (index, imageRef.image, ts)
                }
                inFlight.append(t)
            }
        }
        
        // Prime the initial batch
        startNextIfPossible()
        
        while !inFlight.isEmpty {
            if Task.isCancelled {
                inFlight.forEach { $0.cancel() }
                throw CancellationError()
            }

            // Await the next available task (take the first one)
            let task = inFlight.removeFirst()
            do {
                let result = try await task.value
                collected.append(result)
                completed += 1
                if completed % progressInterval == 0 || completed == totalFrames {
                    let progress = Double(completed) / Double(totalFrames)
                    // logger.debug("🔄 Frame extraction progress: \(Int(progress * 100))% (\(completed)/\(totalFrames))")
                }
                // Start more tasks if we have remaining work
                startNextIfPossible()
            } catch {
                // Cancel remaining tasks and propagate the error
                inFlight.forEach { $0.cancel() }
                throw error
            }
        }
        
        let extractionTime = CFAbsoluteTimeGetCurrent() - startTime
        let framesPerSecond = Double(collected.count) / extractionTime
        // logger.debug("✅ VideoToolbox extraction complete - Extracted \(collected.count) frames in \(String(format: "%.2f", extractionTime)) seconds (\(String(format: "%.1f", framesPerSecond)) frames/sec)")
        
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
        // logger.debug("📐 Calculated aspect ratio: \(ratio) from size: \(videoSize.width)x\(videoSize.height)")
        return ratio
    }
    
    /// Save a mosaic image to disk
    /// - Parameters:
    ///   - mosaic: The mosaic image to save
    ///   - video: The video the mosaic was generated for
    ///   - config: The mosaic configuration
    /// - Returns: The URL of the saved mosaic
    private func saveMosaic(
        _ mosaic: CGImage,
        for video: VideoInput,
        config: MosaicConfiguration,
        forIphone: Bool = false
    ) async throws -> URL {
        let state = signposter.beginInterval("Save Mosaic")
        defer { signposter.endInterval("Save Mosaic", state) }
        signposter.emitEvent("saving mosaic","name : \(video.url.lastPathComponent)")
        // Determine output directory based on configuration
        let dirSuffix = "_Th\(config.width)_\(config.density.name)_\(config.layout.aspectRatio)"
        
        // Determine base output directory
        var baseOutputDirectory: URL
        var mosaicURL: URL!

        // Use structured output directory if metadata is available
        guard let rootFolder = config.outputdirectory else {
            // logger.error("❌ No output directory specified in configuration")
            throw MosaicError.saveFailed(URL(fileURLWithPath: "/dev/null"),
                                        NSError(domain: "com.mosaickit", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: "Missing output directory"]))
        }

        // Generate structured path: {root}/{service}/{creator}/{configHash}/
        baseOutputDirectory = config.generateOutputDirectory(rootDirectory: rootFolder, videoInput: video)

        if baseOutputDirectory.startAccessingSecurityScopedResource() {
            defer { baseOutputDirectory.stopAccessingSecurityScopedResource() }
        }

        try FileManager.default.createDirectory(at: baseOutputDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)

        // Generate filename using configuration method
        let videoURL = video.url
        let originalFilename = videoURL.deletingPathExtension().lastPathComponent
        let filename = config.generateFilename(originalFilename: originalFilename, videoInput: video)

        mosaicURL = baseOutputDirectory.appendingPathComponent(filename)
        
        // logger.debug("💾 Saving mosaic to: \(mosaicURL.path)")
        
        // Check if file exists and handle overwrite option
        if FileManager.default.fileExists(atPath: mosaicURL.path) {
           
                // logger.debug("🔄 Overwriting existing file at: \(mosaicURL.path)")
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
                // logger.error("❌ Failed to create image data")
                throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
            }
            
            try imageData.write(to: mosaicURL)
            // logger.debug("✅ Mosaic saved successfully")
            // logger.debug("📸 Saving as JPEG, quality: \(config.compressionQuality)")
        case .png:
            data = getPngData(from: platformImage)
            guard let imageData = data else {
                // logger.error("❌ Failed to create image data")
                throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
            }
            
            try imageData.write(to: mosaicURL)
            // logger.debug("✅ Mosaic saved successfully")
            // logger.debug("📸 Saving as PNG")
        case .heif:
            if mosaicURL.deletingLastPathComponent().startAccessingSecurityScopedResource() {
                defer { mosaicURL.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
            }
            try await saveAsHEIC(mosaic, to: mosaicURL, quality: Float(config.compressionQuality))
            // logger.debug("📸 Saving as JPEG (HEIF fallback), quality: \(config.compressionQuality)")
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
#elseif canImport(UIKit)
// Adjust the usage in the code above to directly call the built-in UIImage method with CGFloat
// No extension needed for UIImage as it already has pngData() and jpegData(compressionQuality:) methods
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

