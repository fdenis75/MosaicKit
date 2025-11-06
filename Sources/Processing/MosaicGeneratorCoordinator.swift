import Foundation
import OSLog
import SwiftData
@available(macOS 15, iOS 18, *)
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

@available(macOS 15, iOS 18, *)
public struct MosaicGenerationProgress: Sendable {
    /// The video being VideoInput
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
@available(macOS 15, iOS 18, *)
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
@available(macOS 15, iOS 18, *)
public actor MosaicGeneratorCoordinator {
  
  
    
    
    // MARK: - Properties
    
    public let logger = Logger(subsystem: "com.hypermovie", category: "mosaic-coordinator")
    public let mosaicGenerator: MetalMosaicGenerator
    public let concurrencyLimit: Int
    public var activeTasks: [UUID: Task<MosaicGenerationResult, Error>] = [:]
    public var progressHandlers: [UUID: (MosaicGenerationProgress) -> Void] = [:]
    public let modelContext: ModelContext
    
    // MARK: - Initialization
    
    /// Creates a new mosaic generator coordinator
    /// - Parameters:
    ///   - mosaicGenerator: The mosaic generator to use
    ///   - modelContext: The SwiftData model context
    ///   - concurrencyLimit: Maximum number of concurrent generation tasks
    ///   - generatorType: The type of mosaic generator to use (standard, metal, or auto)
    public init(
        mosaicGenerator: (MetalMosaicGenerator)? = nil,
        modelContext: ModelContext,
        concurrencyLimit: Int = 31,
        generatorType: MosaicGeneratorFactory.GeneratorType = .metal
    ) {
        if let generator = mosaicGenerator {
            self.mosaicGenerator = generator
            logger.debug("🎬 MosaicGeneratorCoordinator initialized with provided generator")
        } else {
            let generator = try! MosaicGeneratorFactory.createGenerator()
            self.mosaicGenerator = generator
            logger.debug("🎬 MosaicGeneratorCoordinator initialized with Metal generator")
        }
        
        self.modelContext = modelContext
        self.concurrencyLimit = concurrencyLimit
        logger.debug("🎬 MosaicGeneratorCoordinator initialized with concurrency limit: \(concurrencyLimit)")
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
        
        // Create and start task
        let task = Task<MosaicGenerationResult, Error> {
            do {
                // Report in-progress status
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.1,
                    status: .inProgress
                ))
                
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
    public func cancelGeneration(for video: VideoInput) {
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
        
        // Cancel in generator - use Task to handle actor isolation
        Task {
            await mosaicGenerator.cancel(for: video)
        }
    }
    
    /// Cancel all ongoing mosaic generation operations
    public func cancelAllGenerations() {
        logger.debug("❌ Cancelling all mosaic generation tasks")
        
        // Cancel all tasks
        for (_, task) in activeTasks {
            task.cancel()
        }
        
        // Clear state
        activeTasks.removeAll()
        progressHandlers.removeAll()
        
        // Cancel in generator - use Task to handle actor isolation
        Task {
            await mosaicGenerator.cancelAll()
        }
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
        
        // Dynamically adjust concurrency based on system capabilities
        let processorCount = ProcessInfo.processInfo.activeProcessorCount * 4
        let systemMemory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Double(systemMemory) / 1_073_741_824.0 // Convert to GB
        
        // Calculate optimal concurrency:
        // - Consider both CPU cores and available memory
        // - Higher memory systems can handle more concurrent generations
        // - But we still don't want to overload the system
        let memoryBasedLimit = max(2, Int(memoryGB / config.density.factor)) // Rough estimate: 4GB per concurrent task
        let cpuBasedLimit = max(2, processorCount - 1) // Leave one core free for system
        let dynamicLimit = min(memoryBasedLimit, cpuBasedLimit)
       // let dynamicLimit = concurrencyLimit
        logger.debug("⚙️ Using dynamic concurrency limit of \(dynamicLimit) (CPU: \(processorCount), Memory: \(Int(memoryGB))GB, Config: \(self.concurrencyLimit))")
        
        // Prioritize videos based on various factors
        let prioritizedVideos = videos
        
        // Use TaskGroup for better structured concurrency
        return try await withThrowingTaskGroup(of: MosaicGenerationResult.self) { group in
            var results: [MosaicGenerationResult] = []
            results.reserveCapacity(videos.count) // Pre-allocate for performance
            
            var inProgress = 0
            var completed = 0
            var videoIndex = 0
            
            // Initial batch: fill up to the concurrency limit
            while inProgress < dynamicLimit && videoIndex < prioritizedVideos.count {
                let video = videos[videoIndex]
                videoIndex += 1
                inProgress += 1
                
                // Report status
                progressHandler(MosaicGenerationProgress(
                    video: video,
                    progress: 0.0,
                    status: .queued
                ))
                
                // Add task to group
                group.addTask { @Sendable in
                    // Create individual progress handler to track this video
                    let videoProgressHandler: @Sendable (MosaicGenerationProgress) -> Void = { progress in
                        let updatedProgress = MosaicGenerationProgress(
                            video: progress.video,
                            progress: progress.progress,
                            status: progress.status,
                            outputURL: progress.outputURL,
                            error: progress.error                        )
                        progressHandler(updatedProgress)
                    }
                    
                    do {
                        return try await self.generateMosaic(for: video, config: config, forIphone: forIphone, progressHandler: videoProgressHandler)
                    } catch {
                        return MosaicGenerationResult(video: video, error: error)
                    }
                }
            }
            
            // Process videos as tasks complete, maintaining optimal concurrency
            while let result = try await group.next() {
                results.append(result)
                completed += 1
                inProgress -= 1
                
                // Report aggregated progress (useful for UI progress indicators)
                let overallProgress = Double(completed) / Double(videos.count)
                logger.debug("🔄 Progress: \(Int(overallProgress * 100))% (\(completed)/\(videos.count) complete)")
                
                // Start new tasks as slots become available
                while inProgress < dynamicLimit && videoIndex < prioritizedVideos.count {
                    let video = videos[videoIndex]
                    videoIndex += 1
                    inProgress += 1
                    
                    // Report status
                    progressHandler(MosaicGenerationProgress(
                        video: video,
                        progress: 0.0,
                        status: .queued                    ))
                    
                    // Add next task to group
                    group.addTask { @Sendable in
                        let videoProgressHandler: @Sendable (MosaicGenerationProgress) -> Void = { progress in
                            let updatedProgress = MosaicGenerationProgress(
                                video: progress.video,
                                progress: progress.progress,
                                status: progress.status,
                                outputURL: progress.outputURL,
                                error: progress.error                            )
                            progressHandler(updatedProgress)
                        }
                        
                        do {
                            return try await self.generateMosaic(for: video, config: config, forIphone: forIphone, progressHandler: videoProgressHandler)
                        } catch {
                            return MosaicGenerationResult(video: video, error: error)
                        }
                    }
                }
            }
            
            // Log final results
            let successCount = results.filter { $0.isSuccess }.count
            let failureCount = results.count - successCount
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
        
        return try! videos.sorted { video1id, video2id in
            var video1: VideoInput
            var video2: VideoInput
            do {
                 video1 = video1id
                 video2 = video2id
            } catch {
                logger.error("Error fetching video: \(error)")
                throw error
            }
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

// Placeholder for CoordinatorError - Define this properly elsewhere
enum CoordinatorError: Error {
    case missingVideoID
} 
