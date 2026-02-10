//
//  PreviewGeneratorCoordinator.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import OSLog
import AVFoundation


/// Coordinator for batch preview video generation with concurrency management
@available(macOS 26, iOS 26, *)
public actor PreviewGeneratorCoordinator {

    // MARK: - Properties

    private let previewGenerator: PreviewVideoGenerator
    private let logger = Logger(subsystem: "com.mosaickit", category: "PreviewGeneratorCoordinator")

    /// Active generation tasks keyed by video ID
    private var activeTasks: [UUID: Task<PreviewGenerationResult, Error>] = [:]

    /// Progress handlers for each video, storing the VideoInput alongside the handler
    private var progressHandlers: [UUID: (video: VideoInput, handler: @Sendable (PreviewGenerationProgress) -> Void)] = [:]

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
            progressHandlers[video.id] = (video: video, handler: handler)
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
            progressHandlers[video.id]?.handler(.failed(for: video, error: error))
            progressHandlers.removeValue(forKey: video.id)

            throw error
        }
    }

    /// Generate preview composition for a single video (for video player playback)
    /// - Parameters:
    ///   - video: The source video
    ///   - config: Preview configuration
    ///   - progressHandler: Optional progress callback
    /// - Returns: AVPlayerItem configured with the preview composition
    public func generatePreviewComposition(
        for video: VideoInput,
        config: PreviewConfiguration,
        progressHandler: (@Sendable (PreviewGenerationProgress) -> Void)? = nil
    ) async throws -> AVPlayerItem {
        logger.info("Starting preview composition generation for \(video.title)")

        // Set progress handler
        if let handler = progressHandler {
            progressHandlers[video.id] = (video: video, handler: handler)
            await previewGenerator.setProgressHandler(for: video, handler: handler)
        }

        // Generate composition
        do {
            let playerItem = try await previewGenerator.generateComposition(for: video, config: config)
            logger.info("Preview composition generated successfully")

            // Cleanup
            progressHandlers.removeValue(forKey: video.id)

            return playerItem
        } catch {
            logger.error("Preview composition generation failed: \(error.localizedDescription)")

            // Report failure
            progressHandlers[video.id]?.handler(.failed(for: video, error: error))
            progressHandlers.removeValue(forKey: video.id)

            throw error
        }
    }

    /// Generate preview compositions for multiple videos with concurrency management
    /// - Parameters:
    ///   - videos: Array of videos to process
    ///   - config: Preview configuration
    ///   - progressHandler: Optional progress callback for each video
    /// - Returns: Array of composition results with AVPlayerItems
    public func generatePreviewCompositionsForBatch(
        videos: [VideoInput],
        config: PreviewConfiguration,
        progressHandler: (@Sendable (PreviewGenerationProgress) -> Void)? = nil
    ) async throws -> [PreviewCompositionResult] {
        logger.info("Starting batch preview composition generation for \(videos.count) videos")

        let batchConcurrencyLimit = self.effectiveConcurrencyLimit
        logger.info("Using concurrency limit: \(batchConcurrencyLimit)")

        var results: [PreviewCompositionResult] = []
        var completed = 0
        var successCount = 0
        var failureCount = 0
        var activeTasks = 0

        return try await withThrowingTaskGroup(of: PreviewCompositionResult.self) { group in

            for video in videos {
                // Wait for available slot by collecting a completed task
                while activeTasks >= batchConcurrencyLimit {
                    if let result = try await group.next() {
                        results.append(result)
                        completed += 1
                        activeTasks -= 1
                        if result.isSuccess { successCount += 1 } else { failureCount += 1 }
                        logger.debug("Progress: \(completed)/\(videos.count) complete")
                    }
                }

                // Queue video for processing
                progressHandler?(.queued(for: video))
                activeTasks += 1

                group.addTask(priority: .medium) { @Sendable in
                    try Task.checkCancellation()

                    do {
                        if let handler = progressHandler {
                            await self.previewGenerator.setProgressHandler(for: video, handler: handler)
                        }
                        let playerItem = try await self.previewGenerator.generateComposition(for: video, config: config)
                        return PreviewCompositionResult.success(video: video, playerItem: playerItem)
                    } catch {
                        self.logger.error("Composition failed for: \(video.title) - \(error.localizedDescription)")
                        return PreviewCompositionResult.failure(video: video, error: error)
                    }
                }
            }

            // Collect remaining results
            while let result = try await group.next() {
                results.append(result)
                completed += 1
                activeTasks -= 1
                if result.isSuccess { successCount += 1 } else { failureCount += 1 }
                logger.debug("Progress: \(completed)/\(videos.count) complete")
            }

            logger.info("Batch composition completed - Success: \(successCount), Failed: \(failureCount), Total: \(videos.count)")
            return results
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
        logger.info("Starting batch preview generation for \(videos.count) videos")

        let batchConcurrencyLimit = self.effectiveConcurrencyLimit
        logger.info("Using concurrency limit: \(batchConcurrencyLimit)")

        var results: [PreviewGenerationResult] = []
        var completed = 0
        var successCount = 0
        var failureCount = 0
        var activeTasks = 0

        return try await withThrowingTaskGroup(of: PreviewGenerationResult.self) { group in

            for video in videos {
                // Wait for available slot by collecting a completed task
                while activeTasks >= batchConcurrencyLimit {
                    if let result = try await group.next() {
                        results.append(result)
                        completed += 1
                        activeTasks -= 1
                        if result.isSuccess { successCount += 1 } else { failureCount += 1 }
                        logger.debug("Progress: \(completed)/\(videos.count) complete")
                    }
                }

                // Queue video for processing
                progressHandler?(.queued(for: video))
                activeTasks += 1

                group.addTask(priority: .medium) { @Sendable in
                    try Task.checkCancellation()

                    do {
                        if let handler = progressHandler {
                            await self.previewGenerator.setProgressHandler(for: video, handler: handler)
                        }
                        let outputURL = try await self.previewGenerator.generate(for: video, config: config)
                        return PreviewGenerationResult.success(video: video, outputURL: outputURL)
                    } catch {
                        self.logger.error("Generation failed for: \(video.title) - \(error.localizedDescription)")
                        return PreviewGenerationResult.failure(video: video, error: error)
                    }
                }
            }

            // Collect remaining results
            while let result = try await group.next() {
                results.append(result)
                completed += 1
                activeTasks -= 1
                if result.isSuccess { successCount += 1 } else { failureCount += 1 }
                logger.debug("Progress: \(completed)/\(videos.count) complete")
            }

            logger.info("Batch generation completed - Success: \(successCount), Failed: \(failureCount), Total: \(videos.count)")
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
        progressHandlers[video.id]?.handler(.cancelled(for: video))
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

        // Report cancellations using the stored VideoInput
        for (_, entry) in progressHandlers {
            entry.handler(.cancelled(for: entry.video))
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

        // CPU-based limit: use most cores, leave some for system
        let cpuBasedLimit = max(2, processorCount - 1)

        // Memory-based limit (rough estimate ~500MB per task)
        let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let memoryBasedLimit = max(2, Int(physicalMemoryGB / 0.5))

        let optimal = min(cpuBasedLimit, memoryBasedLimit, 8)
        logger.info("Calculated optimal concurrency: \(optimal) (CPU: \(cpuBasedLimit), Memory: \(memoryBasedLimit))")

        return optimal
    }
}

// MARK: - Performance Metrics

@available(macOS 26, iOS 26, *)
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
