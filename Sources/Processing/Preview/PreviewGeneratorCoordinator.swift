//
//  PreviewGeneratorCoordinator.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import OSLog
import SwiftData

/// Coordinator for batch preview video generation with concurrency management
@available(macOS 15, iOS 18, *)
public actor PreviewGeneratorCoordinator {

    // MARK: - Properties

    private let previewGenerator: PreviewVideoGenerator
    private let logger = Logger(subsystem: "com.mosaickit", category: "PreviewGeneratorCoordinator")

    /// Active generation tasks keyed by video ID
    private var activeTasks: [UUID: Task<PreviewGenerationResult, Error>] = [:]

    /// Progress handlers for each video
    private var progressHandlers: [UUID: @Sendable (PreviewGenerationProgress) -> Void] = [:]

    /// Maximum concurrent preview generations (0 = auto)
    private var concurrencyLimit: Int

    /// Effective concurrency limit (calculated if concurrencyLimit = 0)
    private var effectiveConcurrencyLimit: Int {
        if concurrencyLimit > 0 {
            return concurrencyLimit
        }
        // Auto-calculate based on system resources
        return calculateOptimalConcurrency()
    }

    // MARK: - Initialization

    public init(concurrencyLimit: Int = 0) {
        self.previewGenerator = PreviewVideoGenerator()
        self.concurrencyLimit = concurrencyLimit
        logger.info("PreviewGeneratorCoordinator initialized with concurrency limit: \(concurrencyLimit)")
    }

    // MARK: - Public Methods

    /// Generate preview for a single video
    /// - Parameters:
    ///   - video: The source video
    ///   - config: Preview configuration
    ///   - progressHandler: Optional progress callback
    /// - Returns: URL of the generated preview
    public func generatePreview(
        for video: VideoInput,
        config: PreviewConfiguration,
        progressHandler: (@Sendable (PreviewGenerationProgress) -> Void)? = nil
    ) async throws -> URL {
        logger.info("Starting preview generation for \(video.title)")

        // Set progress handler
        if let handler = progressHandler {
            progressHandlers[video.id] = handler
            await previewGenerator.setProgressHandler(for: video, handler: handler)
        }

        // Generate preview
        do {
            let outputURL = try await previewGenerator.generate(for: video, config: config)
            logger.info("Preview generated: \(outputURL.lastPathComponent)")

            // Cleanup
            progressHandlers.removeValue(forKey: video.id)

            return outputURL
        } catch {
            logger.error("Preview generation failed: \(error.localizedDescription)")

            // Report failure
            progressHandlers[video.id]?(.failed(for: video, error: error))
            progressHandlers.removeValue(forKey: video.id)

            throw error
        }
    }

    /// Generate previews for multiple videos with concurrency management
    /// - Parameters:
    ///   - videos: Array of videos to process
    ///   - config: Preview configuration
    ///   - progressHandler: Optional progress callback for each video
    /// - Returns: Array of generation results
    public func generatePreviewsForBatch(
        videos: [VideoInput],
        config: PreviewConfiguration,
        progressHandler: (@Sendable (PreviewGenerationProgress) -> Void)? = nil
    ) async throws -> [PreviewGenerationResult] {
        logger.info("🎬 Starting batch preview generation for \(videos.count) videos")

        // Determine the effective concurrency limit for this batch
        var effectiveConcurrencyLimit: Int
        if self.concurrencyLimit == 0 {
            // Dynamically adjust concurrency based on system capabilities
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            let systemMemory = ProcessInfo.processInfo.physicalMemory
            let memoryGB = Double(systemMemory) / 1_073_741_824.0 // Convert to GB

            // Calculate optimal concurrency with balanced approach
            let cpuBasedLimit = max(2, processorCount / 2) // Use half of cores to avoid oversubscription
            let memoryPerTask = 0.5 // Estimate 500MB per preview generation task
            let memoryBasedLimit = max(2, Int(memoryGB / memoryPerTask))
            effectiveConcurrencyLimit = min(memoryBasedLimit, cpuBasedLimit, 8) // Cap at 8

            logger.info("⚙️ Using dynamic concurrency limit of \(effectiveConcurrencyLimit) (CPU cores: \(processorCount), Memory: \(Int(memoryGB))GB)")
        } else {
            // Use the configured concurrency limit
            effectiveConcurrencyLimit = self.concurrencyLimit
            logger.info("⚙️ Using configured concurrency limit: \(effectiveConcurrencyLimit)")
        }

        var results: [PreviewGenerationResult] = []
        var completed = 0
        var successCount = 0
        var failureCount = 0
        var activeTasks = 0

        return try await withThrowingTaskGroup(of: PreviewGenerationResult.self) { group in
            var videoIndex = 0

            for video in videos {
                // Check for concurrency limit changes
                if effectiveConcurrencyLimit != self.concurrencyLimit && self.concurrencyLimit > 0 {
                    effectiveConcurrencyLimit = self.concurrencyLimit
                    logger.info("⚙️ Updated effective concurrency to: \(effectiveConcurrencyLimit)")
                }

                // Wait for available slot
                while activeTasks >= effectiveConcurrencyLimit {
                    logger.debug("Threshold reached: \(activeTasks)/\(effectiveConcurrencyLimit)")
                    try await Task.sleep(for: .seconds(0.2))

                    if let result = try await group.next() {
                        results.append(result)
                        completed += 1
                        activeTasks -= 1

                        if result.isSuccess {
                            successCount += 1
                        } else {
                            failureCount += 1
                        }

                        // Report aggregated progress
                        let overallProgress = Double(completed) / Double(videos.count)
                        logger.debug("🔄 Progress: \(Int(overallProgress * 100))% (\(completed)/\(videos.count) complete)")
                    }
                }

                // Queue video for processing
                logger.debug("Adding task for video: \(video.title)")
                progressHandler?(.queued(for: video))

                activeTasks += 1
                videoIndex += 1

                group.addTask(priority: .medium) { @Sendable in
                    // Check for cancellation at start
                    try Task.checkCancellation()

                    // Create individual progress handler to track this video
                    let videoProgressHandler: @Sendable (PreviewGenerationProgress) -> Void = { progress in
                        progressHandler?(progress)
                    }

                    do {
                        self.logger.debug("Starting generation for: \(video.title)")

                        // Set progress handler
                        if let handler = progressHandler {
                            await self.previewGenerator.setProgressHandler(for: video, handler: handler)
                        }

                        // Generate preview
                        let outputURL = try await self.previewGenerator.generate(for: video, config: config)
                        let result = PreviewGenerationResult.success(video: video, outputURL: outputURL)

                        self.logger.debug("Finished generation for: \(video.title)")
                        return result

                    } catch {
                        self.logger.error("Generation failed for: \(video.title) - \(error.localizedDescription)")
                        return PreviewGenerationResult.failure(video: video, error: error)
                    }
                }
            }

            // Collect remaining results
            while let result = try await group.next() {
                logger.debug("Waiting for results")

                results.append(result)
                completed += 1
                activeTasks -= 1

                if result.isSuccess {
                    successCount += 1
                } else {
                    failureCount += 1
                }

                // Report aggregated progress
                let overallProgress = Double(completed) / Double(videos.count)
                logger.debug("🔄 Progress: \(Int(overallProgress * 100))% (\(completed)/\(videos.count) complete)")
            }

            // Log final results
            logger.info("✅ Preview generation completed - Success: \(successCount), Failed: \(failureCount), Total: \(videos.count)")
            return results
        }
    }

    /// Cancel generation for a specific video
    /// - Parameter video: The video to cancel
    public func cancelGeneration(for video: VideoInput) {
        logger.info("Cancelling preview generation for \(video.title)")

        // Cancel the task
        activeTasks[video.id]?.cancel()
        activeTasks.removeValue(forKey: video.id)

        // Cancel in generator
        Task {
            await previewGenerator.cancel(for: video)
        }

        // Report cancellation
        progressHandlers[video.id]?(.cancelled(for: video))
        progressHandlers.removeValue(forKey: video.id)
    }

    /// Cancel all active generations
    public func cancelAllGenerations() {
        logger.info("Cancelling all preview generations")

        // Cancel all tasks
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()

        // Cancel in generator
        Task {
            await previewGenerator.cancelAll()
        }

        // Report cancellations
        for (id, handler) in progressHandlers {
            // Create a temporary VideoInput for cancellation (we don't have the full object)
            // The handler should handle this gracefully
            handler(PreviewGenerationProgress(
                video: VideoInput(url: URL(fileURLWithPath: "/tmp/cancelled")),
                progress: 0.0,
                status: .cancelled
            ))
        }
        progressHandlers.removeAll()
    }

    /// Set the concurrency limit
    /// - Parameter limit: Maximum concurrent generations (0 = auto)
    public func setConcurrencyLimit(_ limit: Int) {
        logger.info("Setting concurrency limit to \(limit)")
        self.concurrencyLimit = limit
    }

    /// Get current concurrency limit
    public func getConcurrencyLimit() -> Int {
        return concurrencyLimit
    }

    /// Get number of active generations
    public func getActiveGenerationCount() -> Int {
        return activeTasks.count
    }

    // MARK: - Private Methods

    private func calculateOptimalConcurrency() -> Int {
        let processorCount = ProcessInfo.processInfo.processorCount

        // Preview generation is less CPU-intensive than mosaic generation
        // but involves significant I/O for reading/writing video files
        // Use a more aggressive default: allow more concurrent operations

        // CPU-based limit: use most cores, leave some for system
        let cpuBasedLimit = max(2, processorCount - 1)

        // Memory-based limit (rough estimate)
        let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        // Assume ~500MB per concurrent preview generation
        let memoryBasedLimit = max(2, Int(physicalMemoryGB / 0.5))

        // Use the minimum of both limits
        let optimal = min(cpuBasedLimit, memoryBasedLimit, 8) // Cap at 8

        logger.info("Calculated optimal concurrency: \(optimal) (CPU: \(cpuBasedLimit), Memory: \(memoryBasedLimit))")

        return optimal
    }
}

// MARK: - Performance Metrics

@available(macOS 15, iOS 18, *)
extension PreviewGeneratorCoordinator {
    /// Get performance metrics
    public func getPerformanceMetrics() -> [String: Any] {
        return [
            "activeTasks": activeTasks.count,
            "concurrencyLimit": concurrencyLimit,
            "effectiveConcurrencyLimit": effectiveConcurrencyLimit,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        ]
    }
}
