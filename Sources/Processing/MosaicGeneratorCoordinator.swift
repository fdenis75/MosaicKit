@preconcurrency import Foundation
import OSLog
@preconcurrency import CoreImage

@available(macOS 26, iOS 26, *)
public struct MosaicGenerationResult: Sendable {
    /// The video that was processed
    public let video: VideoInput

    /// The output URL of the generated mosaic
    public let outputURL: URL?

    /// The error if generation failed
    public let error: Error?

    /// Whether generation was successful
    public var isSuccess: Bool {
        outputURL != nil && error == nil
    }

    /// Creates a new result instance
    public init(video: VideoInput, outputURL: URL? = nil, error: Error? = nil) {
        self.video = video
        self.outputURL = outputURL
        self.error = error
    }
}

@available(macOS 26, iOS 26, *)
public struct MosaicGenerationImage: Sendable {
    /// The video that was processed
    public let video: VideoInput

    /// The generated mosaic image
    public let image: CGImage?

    /// The error if generation failed
    public let error: Error?

    /// Whether generation was successful
    public var isSuccess: Bool {
        image != nil && error == nil
    }

    /// Creates a new image result instance
    public init(video: VideoInput, image: CGImage? = nil, error: Error? = nil) {
        self.video = video
        self.image = image
        self.error = error
    }
}

@available(macOS 26, iOS 26, *)
public struct MosaicGenerationProgress: Sendable {
    /// The video being processed.
    public let video: VideoInput
    
    /// The progress value (0.0 to 1.0)
    public let progress: Double
    
    /// The status of the generation
    public let status: MosaicGenerationStatus
    
    /// The output URL if generation is complete
    public let outputURL: URL?
    
    /// The error if generation failed
    public let error: Error?
    
    /// Creates a new progress information instance
    public init(
        video: VideoInput,
        progress: Double,
        status: MosaicGenerationStatus,
        outputURL: URL? = nil,
        error: Error? = nil
    ) {
        self.video = video
        self.progress = progress
        self.status = status
        self.outputURL = outputURL
        self.error = error
    }
}

/// Status of mosaic generation
@available(macOS 26, iOS 26, *)
public enum MosaicGenerationStatus: Sendable {
    /// Generation is queued
    case queued
    
    /// Generation is in progress
    case inProgress
    
    case countingThumbnails
    case computingLayout
    case extractingThumbnails
    case creatingMosaic
    case savingMosaic
    
    /// Generation is complete
    case completed
    
    /// Generation failed
    case failed
    
    /// Generation was cancelled
    case cancelled
}
/// Coordinator for mosaic generation operations
/// Generic over Generator type to eliminate existential container overhead
@available(macOS 26, iOS 26, *)
public actor MosaicGeneratorCoordinator<Generator: MosaicGeneratorProtocol> {




    // MARK: - Properties

    public let logger = Logger(subsystem: "com.mosaicKit", category: "mosaic-coordinator")
    public let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "mosaic-coordinator")
    public let mosaicGenerator: Generator
    public var concurrencyLimit: Int
    public var activeTasks: [UUID: Task<MosaicGenerationResult, Error>] = [:]
    public var progressHandlers: [UUID: (MosaicGenerationProgress) -> Void] = [:]

    // MARK: - Initialization

    /// Creates a new mosaic generator coordinator with a specific generator
    /// - Parameters:
    ///   - mosaicGenerator: The mosaic generator to use
    ///   - concurrencyLimit: Maximum number of concurrent generation tasks
    public init(
        mosaicGenerator: Generator,
        concurrencyLimit: Int = 0
    ) {
        self.mosaicGenerator = mosaicGenerator
        self.concurrencyLimit = concurrencyLimit
        logger.debug("🎬 MosaicGeneratorCoordinator initialized with provided generator, concurrency limit: \(concurrencyLimit)")
    }

    public func setConcurrencyLimit(_ limit: Int) {
        let oldLimit = self.concurrencyLimit
        self.concurrencyLimit = limit

        // Emit signpost event when concurrency limit changes
        signposter.emitEvent("Concurrency Limit Changed",
            "Old: \(oldLimit), New: \(limit)")
        logger.debug("⚙️ Concurrency limit changed from \(oldLimit) to \(limit)")
    }
    // MARK: - Public Methods
    
    /// Generate a mosaic for a single video
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    ///   - progressHandler: Handler for progress updates
    /// - Returns: The result of mosaic generation
    public func generateMosaic(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false, progressHandler: @escaping @Sendable (MosaicGenerationProgress) -> Void) async throws -> MosaicGenerationResult {

        logger.debug("🎯 Starting mosaic generation for video: \(video.title ?? "N/A")")

        // Safely unwrap video.id
        let videoID = video.id
        // Store progress handler
        progressHandlers[videoID] = progressHandler // Use unwrapped ID

        // Report initial progress
        progressHandler(MosaicGenerationProgress(
            video: video,
            progress: 0.0,
            status: .queued
        ))

        // Create and start task with userInitiated priority for single video generation
        // This ensures user-requested operations get priority over batch operations
        let task = Task<MosaicGenerationResult, Error>(priority: .userInitiated) {
            // Check for cancellation at start
            try Task.checkCancellation()

            do {
                // Report in-progress status
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.0,
                    status: .inProgress
                ))

                // Check for cancellation before expensive operation
                try Task.checkCancellation()

                // Generate mosaic
                await mosaicGenerator.setProgressHandler(for: video, handler: progressHandler)
                let outputURL = try await mosaicGenerator.generate(for: video, config: config, forIphone: forIphone)

                // Report completion
                let result = MosaicGenerationResult(video: video, outputURL: outputURL)
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 1.0,
                    status: .completed,
                    outputURL: outputURL
                ))

                logger.debug("✅ Mosaic generation completed for video: \(video.title ?? "N/A")")
                return result
            } catch {
                // Report failure
                logger.error("❌ Mosaic generation failed for video: \(video.title ?? "N/A") - \(error.localizedDescription)")
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.0,
                    status: .failed,
                    error: error
                ))
                throw error
            }
        }

        // Store task
        activeTasks[videoID] = task // Use unwrapped ID

        // Wait for task to complete
        let result = try await task.value

        // Clean up
        activeTasks[videoID] = nil // Use unwrapped ID
        progressHandlers[videoID] = nil // Use unwrapped ID

        return result
    }

    /// Generate a mosaic image for a single video without saving to disk
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    ///   - forIphone: Whether to use iPhone-optimized layout
    ///   - progressHandler: Handler for progress updates
    /// - Returns: The result of mosaic image generation with CGImage
    public func generateMosaicImage(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false, progressHandler: @escaping @Sendable (MosaicGenerationProgress) -> Void) async throws -> MosaicGenerationImage {

        logger.debug("Starting mosaic image generation for video: \(video.title ?? "N/A")")

        let videoID = video.id
        // Store progress handler
        progressHandlers[videoID] = progressHandler

        // Report initial progress
        progressHandler(MosaicGenerationProgress(
            video: video,
            progress: 0.0,
            status: .queued
        ))

        // Create and start task with userInitiated priority
        let task = Task<MosaicGenerationImage, Error>(priority: .userInitiated) {
            // Check for cancellation at start
            try Task.checkCancellation()

            do {
                // Report in-progress status
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.0,
                    status: .inProgress
                ))

                // Check for cancellation before expensive operation
                try Task.checkCancellation()

                // Generate mosaic image
                await mosaicGenerator.setProgressHandler(for: video, handler: progressHandler)
                let mosaicImage = try await mosaicGenerator.generateMosaicImage(for: video, config: config, forIphone: forIphone)

                // Report completion
                let result = MosaicGenerationImage(video: video, image: mosaicImage)
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 1.0,
                    status: .completed
                ))

                logger.debug("Mosaic image generation completed for video: \(video.title ?? "N/A")")
                return result
            } catch {
                // Report failure
                logger.error("Mosaic image generation failed for video: \(video.title ?? "N/A") - \(error.localizedDescription)")
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.0,
                    status: .failed,
                    error: error
                ))
                throw error
            }
        }

        // Wait for task to complete
        let result = try await task.value

        // Clean up
        progressHandlers[videoID] = nil

        return result
    }

    /// Generate mosaics for videos in a folder
    /// - Parameters:
    ///   - folderURL: The URL of the folder containing videos
    ///   - config: The configuration for mosaic generation
    ///   - recursive: Whether to search for videos recursively
    ///   - progressHandler: Handler for progress updates
    /// - Returns: Array of generation results
  
    
    public func generateMosaicsforbatch(videos: [VideoInput], config: MosaicConfiguration, forIphone: Bool = false, progressHandler: @escaping @Sendable (MosaicGenerationProgress) -> Void) async throws -> [MosaicGenerationResult] {
        return try await generateMosaicsForVideos(videos, config: config, forIphone: forIphone, progressHandler: progressHandler)
    }
    /// Generate mosaics for all videos in a smart folder
    /// - Parameters:
    ///   - smartFolder: The smart folder to generate mosaics for
    ///   - config: The mosaic configuration to use
    ///   - progressHandler: Handler for progress updates
    /// - Returns: Array of generation results
    
    
    /// Generate mosaics for all videos in a folder
    /// - Parameters:
    ///   - folder: The folder to generate mosaics for
    ///   - config: The mosaic configuration to use
    ///   - progressHandler: Handler for progress updates
    /// - Returns: Array of generation results
  
    /// Generate mosaics for all videos in a playlist
    /// - Parameters:
    ///   - playlist: The playlist to generate mosaics for
    ///   - config: The mosaic configuration to use
    ///   - progressHandler: Handler for progress updates
    /// - Returns: Array of generation results
   
    
    /// Cancel mosaic generation for a specific video
    /// - Parameter video: The video to cancel mosaic generation for
    public func cancelGeneration(for video: VideoInput) async {
        // Add default value for optional title
        logger.debug("❌ Cancelling mosaic generation for video: \(video.title ?? "N/A")")

        // Safely unwrap video.id
         let videoID = video.id

        // Cancel task
        activeTasks[videoID]?.cancel() // Use unwrapped ID
        activeTasks[videoID] = nil // Use unwrapped ID

        // Report cancellation
        progressHandlers[videoID]?(MosaicGenerationProgress( // Use unwrapped ID
            video: video,
            progress: 0.0,
            status: .cancelled
        ))

        progressHandlers[videoID] = nil // Use unwrapped ID

        // Cancel in generator - direct await instead of fire-and-forget Task
        await mosaicGenerator.cancel(for: video)
    }
    
    /// Cancel all ongoing mosaic generation operations
    public func cancelAllGenerations() async {
        logger.debug("❌ Cancelling all mosaic generation tasks")

        // Cancel all tasks
        for (_, task) in activeTasks {
            task.cancel()
        }

        // Clear state
        activeTasks.removeAll()
        progressHandlers.removeAll()

        // Cancel in generator - direct await instead of fire-and-forget Task
        await mosaicGenerator.cancelAll()
    }
    
    // MARK: - Private Methods
    
    /// Find videos in a folder from the database
    /// - Parameters:
    ///   - folderURL: The URL of the folder to search
    ///   - recursive: Whether to search for videos recursively
    /// - Returns: Array of videos found in the folder
   
    
    /// Generate mosaics for multiple videos with optimized parallelism
    /// - Parameters:
    ///   - videos: The videos to generate mosaics for
    ///   - config: The configuration for mosaic generation
    ///   - progressHandler: Handler for progress updates
    /// - Returns: Array of generation results
    private func generateMosaicsForVideos(
        _ videos: [VideoInput],
        config: MosaicConfiguration,
        forIphone: Bool = false,
        progressHandler: @escaping @Sendable (MosaicGenerationProgress) -> Void
    ) async throws -> [MosaicGenerationResult] {
        logger.debug("🎬 Starting mosaic generation for \(videos.count) videos")
        let signpostID = signposter.makeSignpostID()
        // Use class-level signposter for performance tracking
        let globalState = signposter.beginInterval("Starting mosaic Generation for batch", id: signpostID)
        let concurrencyState = signposter.beginInterval("Concurrency setup", id: signpostID)
        // Determine the effective concurrency limit for this batch
        // If concurrencyLimit is 0, calculate dynamically based on system resources
        var effectiveConcurrencyLimit: Int
        if self.concurrencyLimit == 0 {
            // Dynamically adjust concurrency based on system capabilities
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            let systemMemory = ProcessInfo.processInfo.physicalMemory
            let memoryGB = Double(systemMemory) / 1_073_741_824.0 // Convert to GB
            
            // Calculate optimal concurrency with balanced approach:
            // - Don't oversubscribe CPU (use half of available cores)
            // - Account for memory-intensive operations (realistic estimate per task)
            let cpuBasedLimit = max(2, processorCount / 2) // Use half of cores to avoid oversubscription
            let memoryPerTask = Double(config.width) * config.density.factor / 2000.0 // More realistic memory estimate in GB
            let memoryBasedLimit = max(2, Int(memoryGB / memoryPerTask))
            effectiveConcurrencyLimit = min(memoryBasedLimit, cpuBasedLimit)
            
           
        
            logger.debug("⚙️ Using dynamic concurrency limit of \(effectiveConcurrencyLimit) (CPU cores: \(processorCount), Memory: \(Int(memoryGB))GB)")
        } else {
            // Use the configured concurrency limit (set via init or setConcurrencyLimit)
            effectiveConcurrencyLimit = self.concurrencyLimit

            logger.debug("⚙️ Using configured concurrency limit: \(effectiveConcurrencyLimit)")
        }
        signposter.endInterval("Concurrency setup", concurrencyState)
        // Prioritize videos based on various factors
        let prioritizedVideos = videos
        
        // Use DiscardingTaskGroup for better memory management (Swift 5.9+)
        // This automatically frees resources as tasks complete instead of accumulating results
        var results: [MosaicGenerationResult] = []
        var completed = 0
        var successCount = 0
        var failureCount = 0
        var activeTasks = 0
        
        return try await withThrowingTaskGroup(of: MosaicGenerationResult.self) { group in
            var videoIndex = 0
            let signpostVideoID = signposter.makeSignpostID()
            for video in prioritizedVideos {
                if effectiveConcurrencyLimit != self.concurrencyLimit {
                    signposter.emitEvent("applying change of concurrency",id: signpostID,
                                         "Active: \(activeTasks)/\(effectiveConcurrencyLimit)")
                    effectiveConcurrencyLimit = self.concurrencyLimit
                    signposter.emitEvent("New effective concurent: ",id: signpostID,
                                         
                                        "effective: (effectiveConcurrencyLimit)")
                }
                // Wait for a slot to become available by getting next completed result
                while activeTasks >= effectiveConcurrencyLimit {
                    logger.debug("Threshold reached: \(activeTasks)/\(effectiveConcurrencyLimit), waiting for task completion")
                    signposter.emitEvent("Waiting for slot", id: signpostID,
                                         "Active: \(activeTasks)/\(effectiveConcurrencyLimit)")

                    // group.next() properly suspends until a result is available - no polling needed
                    if let result = try await group.next() {
                        results.append(result)
                        completed += 1
                        activeTasks -= 1
                        signposter.emitEvent("Result arrived", id: signpostID)

                        if result.isSuccess {
                            successCount += 1
                        } else {
                            failureCount += 1
                        }

                        // Report aggregated progress (useful for UI progress indicators)
                        let overallProgress = Double(completed) / Double(videos.count)
                        logger.debug("🔄 Progress: \(Int(overallProgress * 100))% (\(completed)/\(videos.count) complete)")
                    }
                }
                
                logger.debug("Adding tasks")
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.0,
                    status: .queued
                ))
                // Emit signpost event when adding task to group
                activeTasks += 1
                
                signposter.emitEvent("Task Added to Group",
                                     "Video: \(video.title), Index: \(videoIndex), Active: \(activeTasks)/\(effectiveConcurrencyLimit)")
               // let videoProcessstate = signposter.beginInterval("processing video", "Video: \(video.title)")
                group.addTask(priority: .medium) { @Sendable in
                    // Check for cancellation at start
                    try Task.checkCancellation()
                    
                    // Create individual progress handler to track this video
                    let videoProgressHandler: @Sendable (MosaicGenerationProgress) -> Void = { progress in
                        progressHandler(progress)
                    }
                    let videoProcessstate = self.signposter.beginInterval("processing video",id: signpostVideoID,  "Video: \(video.title)")
                    do {
                        
                        self.logger.debug("starting generation")
                        let result = try await self.generateMosaic(
                            for: video,
                            config: config,
                            forIphone: forIphone,
                            progressHandler: videoProgressHandler
                        )
                        self.logger.debug("finished generation")
                        self.signposter.endInterval("processing video", videoProcessstate,"Video: \(video.title)")
                        
                        return result
                        
                    } catch {
                        self.signposter.endInterval("processing video", videoProcessstate,"Error Video: \(video.title)")
                        return MosaicGenerationResult(video: video, error: error)
                    }
                }
            }
            
            
            while let result = try await group.next() {
                self.logger.debug("wainting results")
                
                results.append(result)
                completed += 1
                activeTasks -= 1
                //self.logger.debug("ersult new active task value: \(activeTasks)")
                self.logger.debug("result arrived")
                
                if result.isSuccess {
                    successCount += 1
                } else {
                    failureCount += 1
                }
                
                // Report aggregated progress (useful for UI progress indicators)
                let overallProgress = Double(completed) / Double(videos.count)
                logger.debug("🔄 Progress: \(Int(overallProgress * 100))% (\(completed)/\(videos.count) complete)")
                
            }
            
            
            
            // Log final results
            logger.debug("✅ Mosaic generation completed - Success: \(successCount), Failed: \(failureCount), Total: \(videos.count)")
            return results
        }
        }
    
            
        
    
    /// Prioritize videos for processing based on various factors
    /// - Parameter videos: The videos to prioritize
    /// - Returns: Videos sorted by priority
    private func prioritizeVideos(_ videos: [VideoInput]) -> [VideoInput] {
        logger.debug("🔄 Prioritizing \(videos.count) videos for processing")
        
        // Sort videos based on a weighted priority algorithm:
        // 1. Shorter videos get higher priority (faster to process)
        // 2. Already cached videos get higher priority
        // 3. Higher resolution videos get slightly lower priority (more resource-intensive)

        return videos.sorted { video1, video2 in
            var score1: Double = 0
            var score2: Double = 0

            // Factor 1: Duration - shorter videos get higher score (negative correlation)
            // Clamp to 1-300 seconds range for scoring purposes
            // Provide default value for optional duration
            let duration1 = min(300, max(1, video1.duration ?? 300))
            let duration2 = min(300, max(1, video2.duration ?? 300))
            score1 += 300.0 / duration1 * 10 // Shorter = higher score, max weight 10
            score2 += 300.0 / duration2 * 10

            // Factor 2: Already has thumbnail/cached data - bonus points


            // Factor 3: Resolution - lower resolution gets higher score (easier to process)
            let resolution1 = (video1.width ?? 1920) * (video1.height ?? 1080)
            let resolution2 = (video2.width ?? 1920) * (video2.height ?? 1080)
            // Normalize to 0-5 range based on 4K resolution as upper bound
            let resolutionMax = 3840 * 2160
            score1 += 5.0 * (1.0 - min(1.0, Double(resolution1) / Double(resolutionMax)))
            score2 += 5.0 * (1.0 - min(1.0, Double(resolution2) / Double(resolutionMax)))

            // Return comparison result (higher score comes first)
            return score1 > score2
        }
        
    }
}

// MARK: - Convenience Factory Functions

/// Creates a coordinator with auto-generated Metal generator (macOS only)
/// - Parameter concurrencyLimit: Maximum number of concurrent generation tasks
/// - Returns: A coordinator with Metal generator for maximum performance
#if os(macOS)
@available(macOS 26, *)
public func createMosaicCoordinatorWithMetal(concurrencyLimit: Int = 0) throws -> MosaicGeneratorCoordinator<MetalMosaicGenerator> {
    let generator = try MetalMosaicGenerator()
    return MosaicGeneratorCoordinator(mosaicGenerator: generator, concurrencyLimit: concurrencyLimit)
}
#endif

/// Creates a coordinator with Core Graphics generator (cross-platform)
/// - Parameter concurrencyLimit: Maximum number of concurrent generation tasks
/// - Returns: A coordinator with Core Graphics generator
@available(macOS 26, iOS 26, *)
public func createMosaicCoordinatorWithCoreGraphics(concurrencyLimit: Int = 0) throws -> MosaicGeneratorCoordinator<CoreGraphicsMosaicGenerator> {
    let generator = try CoreGraphicsMosaicGenerator()
    return MosaicGeneratorCoordinator(mosaicGenerator: generator, concurrencyLimit: concurrencyLimit)
}

/// Creates a coordinator with the default generator for the current platform
/// - Parameter concurrencyLimit: Maximum number of concurrent generation tasks
/// - Returns: A coordinator with the optimal generator for this platform
#if os(macOS)
@available(macOS 26, *)
public func createDefaultMosaicCoordinator(concurrencyLimit: Int = 0) throws -> MosaicGeneratorCoordinator<MetalMosaicGenerator> {
    try createMosaicCoordinatorWithMetal(concurrencyLimit: concurrencyLimit)
}
#else
@available(iOS 26, *)
public func createDefaultMosaicCoordinator(concurrencyLimit: Int = 0) throws -> MosaicGeneratorCoordinator<CoreGraphicsMosaicGenerator> {
    try createMosaicCoordinatorWithCoreGraphics(concurrencyLimit: concurrencyLimit)
}
#endif

// Placeholder for CoordinatorError - Define this properly elsewhere
enum CoordinatorError: Error {
    case missingVideoID
}
