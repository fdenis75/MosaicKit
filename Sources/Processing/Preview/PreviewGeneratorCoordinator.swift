import Foundation
import OSLog
import AVFoundation


/// Coordinator for batch preview video generation with concurrency management
// @available(macOS 26, iOS 26, *)
public actor PreviewGeneratorCoordinator {

    // MARK: - Properties

    private let previewGenerator: PreviewVideoGenerator
    private let logger = Logger(subsystem: "com.mosaickit", category: "PreviewGeneratorCoordinator")

    /// Active generation tasks keyed by video ID
    private var activeTasks: [UUID: Task<URL, Error>] = [:]
    private var activeCompositionTasks: [UUID: Task<AVPlayerItem, Error>] = [:]

    /// Progress handlers for each video, storing the VideoInput alongside the handler
    private var progressHandlers: [UUID: (video: VideoInput, handler: @Sendable (PreviewGenerationProgress) -> Void)] = [:]

    /// Maximum concurrent preview generations (0 = auto)
    private var concurrencyLimit: Int

    /// Monotonic batch generation counter. `cancelAllGenerations()` bumps it so any
    /// in-flight batch loop notices, stops dequeuing queued videos, and throws
    /// `CancellationError` instead of silently starting the rest of the batch.
    private var batchEpoch: Int = 0

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

        defer {
            progressHandlers.removeValue(forKey: video.id)
        }

        do {
            let outputURL = try await runTrackedGeneration(for: video, config: config)
            logger.info("Preview generated: \(outputURL.lastPathComponent)")
            return outputURL
        } catch {
            if Self.isCancellation(error) {
                logger.info("Preview generation cancelled for \(video.title)")
                progressHandlers[video.id]?.handler(.cancelled(for: video))
            } else {
                logger.error("Preview generation failed: \(error.localizedDescription)")
                progressHandlers[video.id]?.handler(.failed(for: video, error: error))
            }
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

        defer {
            progressHandlers.removeValue(forKey: video.id)
        }

        do {
            let playerItem = try await runTrackedCompositionGeneration(for: video, config: config)
            logger.info("Preview composition generated successfully")
            return playerItem
        } catch {
            if Self.isCancellation(error) {
                logger.info("Preview composition generation cancelled for \(video.title)")
                progressHandlers[video.id]?.handler(.cancelled(for: video))
            } else {
                logger.error("Preview composition generation failed: \(error.localizedDescription)")
                progressHandlers[video.id]?.handler(.failed(for: video, error: error))
            }
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

        let epoch = batchEpoch
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

                // Stop dequeuing if cancelAllGenerations() arrived after this batch started
                if batchEpoch != epoch {
                    logger.info("Batch composition cancelled — stopping before \(video.title)")
                    group.cancelAll()
                    throw CancellationError()
                }

                // Queue video for processing
                progressHandler?(.queued(for: video))
                activeTasks += 1

                group.addTask(priority: .utility) { @Sendable in
                    try Task.checkCancellation()

                    do {
                        if let handler = progressHandler {
                            await self.previewGenerator.setProgressHandler(for: video, handler: handler)
                        }
                        let playerItem = try await self.runTrackedCompositionGeneration(for: video, config: config, batchEpoch: epoch)
                        return PreviewCompositionResult.success(video: video, playerItem: playerItem)
                    } catch {
                        // A batch-wide cancel tears the whole group down; a single-video
                        // cancel or ordinary failure only affects this video's result.
                        if await self.batchWasCancelled(epoch) {
                            throw CancellationError()
                        }
                        if Self.isCancellation(error) {
                            progressHandler?(.cancelled(for: video))
                        } else {
                            self.logger.error("Composition failed for: \(video.title) - \(error.localizedDescription)")
                        }
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

                if batchEpoch != epoch {
                    logger.info("Batch composition cancelled during drain")
                    group.cancelAll()
                    throw CancellationError()
                }
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

        let epoch = batchEpoch
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

                // Stop dequeuing if cancelAllGenerations() arrived after this batch started
                if batchEpoch != epoch {
                    logger.info("Batch generation cancelled — stopping before \(video.title)")
                    group.cancelAll()
                    throw CancellationError()
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
                        let outputURL = try await self.runTrackedGeneration(for: video, config: config, batchEpoch: epoch)
                        return PreviewGenerationResult.success(video: video, outputURL: outputURL)
                    } catch {
                        // A batch-wide cancel tears the whole group down; a single-video
                        // cancel or ordinary failure only affects this video's result.
                        if await self.batchWasCancelled(epoch) {
                            throw CancellationError()
                        }
                        if Self.isCancellation(error) {
                            progressHandler?(.cancelled(for: video))
                        } else {
                            self.logger.error("Generation failed for: \(video.title) - \(error.localizedDescription)")
                        }
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

                if batchEpoch != epoch {
                    logger.info("Batch generation cancelled during drain")
                    group.cancelAll()
                    throw CancellationError()
                }
            }

            logger.info("Batch generation completed - Success: \(successCount), Failed: \(failureCount), Total: \(videos.count)")
            return results
        }
    }

    /// Cancel generation for a specific video
    /// - Parameter video: The video to cancel
    public func cancelGeneration(for video: VideoInput) async {
        logger.info("Cancelling preview generation for \(video.title)")

        // Cancel the task
        activeTasks[video.id]?.cancel()
        activeTasks.removeValue(forKey: video.id)
        activeCompositionTasks[video.id]?.cancel()
        activeCompositionTasks.removeValue(forKey: video.id)

        // Cancel in generator
        await previewGenerator.cancel(for: video)

        // Report cancellation
        progressHandlers[video.id]?.handler(.cancelled(for: video))
        progressHandlers.removeValue(forKey: video.id)
    }

    /// Cancel all active generations.
    ///
    /// This cancels every in-flight generation *and* stops any running batch:
    /// videos still queued inside `generatePreviewsForBatch` /
    /// `generatePreviewCompositionsForBatch` are not started, and the batch call
    /// throws `CancellationError`.
    public func cancelAllGenerations() async {
        logger.info("Cancelling all preview generations")

        // Stop in-flight batch loops from dequeuing further videos
        batchEpoch += 1

        // Cancel all tasks
        for (_, task) in activeTasks { task.cancel() }
        for (_, task) in activeCompositionTasks { task.cancel() }
        activeTasks.removeAll()
        activeCompositionTasks.removeAll()

        // Cancel in generator
        await previewGenerator.cancelAll()

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

    /// Runs a single preview generation as a task registered in `activeTasks`, so
    /// `cancelGeneration(for:)` and `cancelAllGenerations()` can reach it, and
    /// bridges cancellation of the caller (e.g. a batch group child) into that task.
    ///
    /// When called from a batch, `batchEpoch` carries the epoch captured at batch
    /// start. The epoch guard and the task registration run in one actor-isolated
    /// synchronous window, so a `cancelAllGenerations()` call can never slip
    /// between them: it either bumps the epoch first (guard throws, nothing
    /// starts) or finds the task already registered and cancels it.
    private func runTrackedGeneration(
        for video: VideoInput,
        config: PreviewConfiguration,
        batchEpoch epoch: Int? = nil
    ) async throws -> URL {
        if let epoch, batchEpoch != epoch { throw CancellationError() }

        let task = Task<URL, Error> { [previewGenerator, video, config] in
            try await self.executeWithBackgroundRetry(videoTitle: video.title, config: config) {
                try await previewGenerator.generate(for: video, config: config)
            }
        }
        activeTasks[video.id] = task
        defer { activeTasks.removeValue(forKey: video.id) }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Composition counterpart of `runTrackedGeneration(for:config:batchEpoch:)`,
    /// registered in `activeCompositionTasks`.
    private func runTrackedCompositionGeneration(
        for video: VideoInput,
        config: PreviewConfiguration,
        batchEpoch epoch: Int? = nil
    ) async throws -> AVPlayerItem {
        if let epoch, batchEpoch != epoch { throw CancellationError() }

        let task = Task<AVPlayerItem, Error> { [previewGenerator, video, config] in
            try await self.executeWithBackgroundRetry(videoTitle: video.title, config: config) {
                try await previewGenerator.generateComposition(for: video, config: config)
            }
        }
        activeCompositionTasks[video.id] = task
        defer { activeCompositionTasks.removeValue(forKey: video.id) }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Whether a `cancelAllGenerations()` call happened after the batch that
    /// captured `epoch` started.
    private func batchWasCancelled(_ epoch: Int) -> Bool {
        batchEpoch != epoch
    }

    /// Whether `error` represents cancellation (task-level or preview-level).
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case PreviewError.cancelled = error { return true }
        return false
    }

    private func calculateOptimalConcurrency() -> Int {
        let processorCount = ProcessInfo.processInfo.processorCount

        // CPU-based limit: use most cores, leave some for system
        let cpuBasedLimit = max(2, processorCount - 1)

        // Memory-based limit (rough estimate ~500MB per task)
        let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let memoryBasedLimit = max(2, Int(physicalMemoryGB / 0.5))

        // Limit dynamic concurrency of video exports to a maximum of 2.
        // Hardware encoders (VideoToolbox) on Apple Silicon/iOS have limited physical channels (typically 2-3).
        // Running more than 2 high-definition encodes concurrently causes resource starvation and VideoToolbox queue stalls.
        let optimal = min(cpuBasedLimit, memoryBasedLimit, 2)
        logger.info("Calculated optimal concurrency: \(optimal) (CPU: \(cpuBasedLimit), Memory: \(memoryBasedLimit))")

        return optimal
    }
    
    /// Executes a generation operation with automatic background suspension retry logic.
    ///
    /// Respects `config.enableAppLifecycleMonitor` (skips foreground waits when `false`)
    /// and `config.enableExportRetry` (skips retries when `false`).
    private func executeWithBackgroundRetry<T: Sendable>(
        videoTitle: String,
        config: PreviewConfiguration,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        let maxAttempts = config.enableExportRetry ? 3 : 1

        while true {
            do {
                try Task.checkCancellation()
                if config.enableAppLifecycleMonitor {
                    await AppLifecycleMonitor.shared.waitUntilForeground()
                }
                try Task.checkCancellation()
                return try await operation()
            } catch {
                let isStalled: Bool
                if case PreviewError.exportStalled(_) = error {
                    isStalled = true
                } else if case PreviewError.encodingFailed(_, let underlyingError) = error {
                    if let nsError = underlyingError as NSError?, nsError.domain == AVFoundationErrorDomain, nsError.code == -11847 {
                        isStalled = true
                    } else {
                        isStalled = false
                    }
                } else if let nsError = error as NSError?, nsError.domain == AVFoundationErrorDomain, nsError.code == -11847 {
                    isStalled = true
                } else {
                    isStalled = false
                }

                if isStalled && attempt < maxAttempts && !Task.isCancelled {
                    logger.warning("Export stalled/interrupted for \(videoTitle) (Attempt \(attempt)/\(maxAttempts)). Retrying when foregrounded...")
                    attempt += 1
                    if config.enableAppLifecycleMonitor {
                        await AppLifecycleMonitor.shared.waitUntilForeground()
                    }
                    // A throwing sleep aborts the retry loop when the task is cancelled
                    // (`try?` would swallow the CancellationError and retry anyway).
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }
        }
    }
}

// MARK: - Performance Metrics

// @available(macOS 26, iOS 26, *)
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
