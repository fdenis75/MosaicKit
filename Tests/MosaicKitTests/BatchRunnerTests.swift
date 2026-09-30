import Foundation
import CoreGraphics
import Synchronization
import Testing
@testable import MosaicKit

/// The batch runners (plan step S-3) and per-attempt tracking in the mosaic coordinator (I-15).
///
/// The mosaic cases use `FakeMosaicGenerator`, which only sleeps, so they check scheduling
/// (concurrency, `.queued` events, results, cancellation) in milliseconds without decoding
/// video. The preview case runs a real composition-only batch on the embedded video.
struct MosaicBatchRunnerTests {

    @Test("A mosaic batch runs every video, never exceeds the concurrency limit, and reports .queued")
    func batchRespectsLimit() async throws {
        let generator = FakeMosaicGenerator(delay: .milliseconds(300))
        let coordinator = MosaicGeneratorCoordinator(mosaicGenerator: generator, concurrencyLimit: 2)
        let videos = makeVideos(count: 6)
        let events = ProgressEvents()

        let results = try await coordinator.generateMosaicsforbatch(videos: videos, config: .default) { events.record($0) }

        #expect(results.count == videos.count)
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(Set(results.map(\.video.id)) == Set(videos.map(\.id)))
        #expect(await generator.started == videos.count)
        #expect(await generator.maxRunning == 2, "At most 2 jobs may run at once, and 6 videos should fill both slots")
        for video in videos {
            #expect(events.statuses(for: video.id).contains(.queued))
            #expect(events.statuses(for: video.id).last == .completed)
        }
    }

    @Test("A file batch inspects each file inside its job and returns one result per file")
    func fileBatchReturnsOneResultPerFile() async throws {
        let generator = FakeMosaicGenerator(delay: .milliseconds(20))
        let coordinator = MosaicGeneratorCoordinator(mosaicGenerator: generator, concurrencyLimit: 2)
        let urls = makeVideos(count: 3).map(\.url)

        let results = try await coordinator.generateMosaicsForFiles(urls, config: .default) { _ in }

        #expect(results.count == urls.count)
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(Set(results.map(\.video.url)) == Set(urls))
        #expect(await generator.maxRunning <= 2)
    }

    @Test("cancelAllGenerations stops a mosaic batch: no further videos start and the batch throws")
    func cancelAllStopsBatch() async throws {
        let generator = FakeMosaicGenerator(delay: .seconds(30))
        let coordinator = MosaicGeneratorCoordinator(mosaicGenerator: generator, concurrencyLimit: 2)
        let videos = makeVideos(count: 5)

        let batch = Task { try await coordinator.generateMosaicsforbatch(videos: videos, config: .default) { _ in } }
        try await waitUntil { await generator.started == 2 }
        await coordinator.cancelAllGenerations()

        await #expect(throws: CancellationError.self) { try await batch.value }
        #expect(await generator.started == 2, "Queued videos must not start after cancelAllGenerations()")
    }

    @Test("Cancelling a video cancels every concurrent attempt on it (I-15)")
    func cancelReachesEveryAttempt() async throws {
        let generator = FakeMosaicGenerator(delay: .seconds(30))
        let coordinator = MosaicGeneratorCoordinator(mosaicGenerator: generator, concurrencyLimit: 2)
        let video = try #require(makeVideos(count: 1).first)
        let first = ProgressEvents()
        let second = ProgressEvents()

        let attemptA = Task { try await coordinator.generateMosaic(for: video, config: .default) { first.record($0) } }
        let attemptB = Task { try await coordinator.generateMosaic(for: video, config: .default) { second.record($0) } }
        try await waitUntil { await generator.started == 2 }

        await coordinator.cancelGeneration(for: video)

        // Before I-15, the second attempt overwrote the first one's entry, so the first kept
        // running for the full 30 s and succeeded.
        await #expect(throws: (any Error).self) { try await attemptA.value }
        await #expect(throws: (any Error).self) { try await attemptB.value }
        #expect(first.statuses(for: video.id).contains(.cancelled))
        #expect(second.statuses(for: video.id).contains(.cancelled))
        #expect(await coordinator.activeTasks.isEmpty)
    }

    // MARK: - Helpers

    /// Inputs built without I/O; the fake generator never opens the files.
    private func makeVideos(count: Int) -> [VideoInput] {
        (0..<count).map { index in
            VideoInput(canonicalID: UUID(),
                       url: FileManager.default.temporaryDirectory.appendingPathComponent("batch-runner-\(index)-\(UUID().uuidString).mp4"),
                       duration: 60, width: 1920, height: 1080)
        }
    }
}

struct PreviewBatchRunnerTests {

    @Test("A preview composition batch returns one result per video and reports .queued for each")
    func compositionBatchReturnsOneResultPerVideo() async throws {
        let videoURL = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"),
                                    "Missing test fixture test_video.mp4")
        let first = try await VideoInput(from: videoURL)
        let videos = [first, first.withID(UUID())]
        let config = PreviewConfiguration(
            targetDuration: 10,
            density: .xxl,
            format: .mp4,
            includeAudio: false,
            enableAppLifecycleMonitor: false,
            enableExportRetry: false
        )
        let queued = QueuedIDs()

        let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: 1)
        let results = try await coordinator.generatePreviewCompositionsForBatch(videos: videos, config: config) { progress in
            if progress.status == .queued { queued.insert(progress.video.id) }
        }

        #expect(results.count == videos.count)
        #expect(results.allSatisfy { $0.isSuccess }, "Failures: \(results.compactMap { $0.error?.localizedDescription })")
        #expect(queued.ids == Set(videos.map(\.id)))
    }
}

// MARK: - Test doubles

/// A mosaic generator that only sleeps for `delay` (throwing if cancelled) and records how many
/// jobs started and how many ran at once. `cancel(for:)` is deliberately a no-op, so a job stops
/// only when the coordinator cancels its task.
private actor FakeMosaicGenerator: MosaicGeneratorProtocol {
    let delay: Duration
    private(set) var started = 0
    private(set) var maxRunning = 0
    private var running = 0

    init(delay: Duration) { self.delay = delay }

    func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) async throws -> URL {
        started += 1
        running += 1
        maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        try await Task.sleep(for: delay)
        return video.url
    }

    func generateMosaicImage(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) async throws -> CGImage {
        throw MosaicError.processingFailed("FakeMosaicGenerator does not render images")
    }

    func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL] { [] }
    func cancel(for video: VideoInput) {}
    func cancelAll() {}
    func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void) {}
    func getPerformanceMetrics() -> [String: Any] { [:] }
}

/// Thread-safe log of progress statuses per video.
private final class ProgressEvents: Sendable {
    private let events = Mutex<[(UUID, MosaicGenerationStatus)]>([])

    func record(_ progress: MosaicGenerationProgress) {
        events.withLock { $0.append((progress.video.id, progress.status)) }
    }

    func statuses(for videoID: UUID) -> [MosaicGenerationStatus] {
        events.withLock { $0.filter { $0.0 == videoID }.map(\.1) }
    }
}

/// Thread-safe set of video IDs reported `.queued`.
private final class QueuedIDs: Sendable {
    private let storage = Mutex<Set<UUID>>([])
    func insert(_ id: UUID) { storage.withLock { _ = $0.insert(id) } }
    var ids: Set<UUID> { storage.withLock { $0 } }
}

/// Polls `condition` every 10 ms for up to 10 s.
private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
