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
        logger.info("Starting batch preview generation for \(videos.count) videos")

        var results: [PreviewGenerationResult] = []
        let limit = effectiveConcurrencyLimit

        logger.info("Using concurrency limit: \(limit)")

        // Process videos with concurrency control
        try await withThrowingTaskGroup(of: PreviewGenerationResult.self) { group in
            var pendingVideos = videos
            var activeCount = 0

            // Queue initial batch
            while activeCount < limit && !pendingVideos.isEmpty {
                let video = pendingVideos.removeFirst()
                addGenerationTask(for: video, config: config, to: &group, progressHandler: progressHandler)
                activeCount += 1
            }

            // Process results and queue remaining videos
            while let result = try await group.next() {
                results.append(result)
                activeCount -= 1

                // Queue next video if available
                if !pendingVideos.isEmpty {
                    let video = pendingVideos.removeFirst()
                    addGenerationTask(for: video, config: config, to: &group, progressHandler: progressHandler)
                    activeCount += 1
                }
            }
        }

        logger.info("Batch preview generation completed: \(results.filter { $0.isSuccess }.count)/\(videos.count) successful")

        return results
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

    private func addGenerationTask(
        for video: VideoInput,
        config: PreviewConfiguration,
        to group: inout ThrowingTaskGroup<PreviewGenerationResult, Error>,
        progressHandler: (@Sendable (PreviewGenerationProgress) -> Void)?
    ) {
        // Set progress handler
        if let handler = progressHandler {
            progressHandlers[video.id] = handler
            Task {
                await previewGenerator.setProgressHandler(for: video, handler: handler)
            }
        }

        // Report queued status
        progressHandlers[video.id]?(.queued(for: video))

        // Create and store task
        let task = Task<PreviewGenerationResult, Error> {
            do {
                let outputURL = try await previewGenerator.generate(for: video, config: config)
                let result = PreviewGenerationResult.success(video: video, outputURL: outputURL)

                // Cleanup
                await self.cleanupAfterGeneration(for: video)

                return result
            } catch {
                let result = PreviewGenerationResult.failure(video: video, error: error)

                // Report failure
                await self.reportFailure(for: video, error: error)

                // Cleanup
                await self.cleanupAfterGeneration(for: video)

                return result
            }
        }

        activeTasks[video.id] = task
        group.addTask { try await task.value }
    }

    private func cleanupAfterGeneration(for video: VideoInput) {
        activeTasks.removeValue(forKey: video.id)
        progressHandlers.removeValue(forKey: video.id)
    }

    private func reportFailure(for video: VideoInput, error: Error) {
        progressHandlers[video.id]?(.failed(for: video, error: error))
    }

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
