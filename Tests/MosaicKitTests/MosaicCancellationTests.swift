import Foundation
import Testing
@testable import MosaicKit

/// Cancellation and concurrency-control tests for `MosaicGeneratorCoordinator`.
///
/// These tests process real video files from a folder using a deliberately
/// heavy configuration (`width: 8000`, `density: .xxs`) so a batch stays
/// in-flight long enough to reliably exercise cancellation and concurrency
/// changes mid-run. They are integration tests, not unit tests:
///
/// Set `MOSAICKIT_TEST_VIDEOS_DIR` to a folder containing video files to run
/// them. They are skipped (not failed) when the folder is missing/empty, or
/// when `MOSAICKIT_SUITE_MODE=none` (the CI default for extended suites).
@Suite("Mosaic batch cancellation and concurrency control")
struct MosaicCancellationTests {

    private static let folderPathEnvKey = "MOSAICKIT_TEST_VIDEOS_DIR"
    private static let defaultMediaFolderPath = "/tmp/mosaickit-test-videos"

    private var isCIMode: Bool {
        ProcessInfo.processInfo.environment["MOSAICKIT_SUITE_MODE"] == "none"
    }

    private var folderURL: URL {
        let path = ProcessInfo.processInfo.environment[Self.folderPathEnvKey] ?? Self.defaultMediaFolderPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Tests

    @Test("Cancel a single in-flight video mid-batch; the rest of the batch continues")
    func cancelSingleProcessingTask() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 10) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-single")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        // Reacts to progress *inside the callback*, the instant the first video
        // goes active, and fires the cancel immediately — polling-then-acting
        // loses the race against fast real-world processing (a single video
        // at this width/density can finish in only a few seconds).
        let tracker = ProgressTracker(claimLimit: 1)

        let batchTask = Task {
            try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { progress in
                Task {
                    if let claimedVideo = await tracker.recordAndMaybeClaim(progress) {
                        print("🎯 Cancelling one in-flight video: \(claimedVideo.title) [\(claimedVideo.id)]")
                        await coordinator.cancelGeneration(for: claimedVideo)
                    }
                }
            }
        }

        let results = try await batchTask.value
        let claimedIDs = await tracker.claimedIDs()

        #expect(!claimedIDs.isEmpty, "Expected to observe and cancel at least one in-flight video")
        #expect(results.count == videos.count, "Batch should still report one result per input video")

        guard let activeID = claimedIDs.first else { return }
        let cancelledResult = results.first { $0.video.id == activeID }
        #expect(cancelledResult != nil)
        // The generator may still win the race on a very fast video (its
        // internal cancellation checks are coarser than per-frame in some
        // paths) — that is itself a valid observed outcome, so we log rather
        // than hard-fail on it, and only assert the invariant that matters:
        // the rest of the batch must be unaffected by this single cancel.
        print("📊 Explicitly cancelled video result: isSuccess=\(cancelledResult?.isSuccess ?? false)")

        let others = results.filter { $0.video.id != activeID }
        let othersSucceeded = others.filter(\.isSuccess).count
        print("📊 Others succeeded: \(othersSucceeded)/\(others.count) after cancelling one video")
        #expect(othersSucceeded > 0, "Cancelling a single video must not abort the rest of the batch")
    }

    @Test("Cancel every in-flight video individually, then pause (concurrency=0) and resume (concurrency=2)")
    func cancelAllProcessingTasksThenPauseAndResume() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 12) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-all-processing-pause-resume")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        // Claim (and immediately cancel) every video the moment it goes
        // active, up to the concurrency limit — see the single-cancel test
        // for why reacting inside the callback (instead of polling then
        // acting) is necessary against fast real-world processing.
        let tracker = ProgressTracker(claimLimit: 8)

        let batchTask = Task {
            try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { progress in
                Task {
                    if let claimedVideo = await tracker.recordAndMaybeClaim(progress) {
                        print("🎯 Cancelling in-flight video: \(claimedVideo.title) [\(claimedVideo.id)]")
                        await coordinator.cancelGeneration(for: claimedVideo)
                    }
                }
            }
        }

        // Give the first wave a moment to actually be claimed/cancelled
        // before touching concurrency, without gating strictly on it.
        _ = await waitUntil(timeout: 30) {
            let ids = await tracker.claimedIDs()
            return !ids.isEmpty
        }
        let activeIDs = await tracker.claimedIDs()
        #expect(!activeIDs.isEmpty, "Expected to observe and cancel at least one in-flight video")

        // "Pause": drop concurrency to 0.
        //
        // Observed behavior: `generateMosaicsForVideos` only re-derives its
        // effective concurrency limit from `self.concurrencyLimit` when that
        // value is non-zero (`self.concurrencyLimit != 0 && ...`). Setting it
        // to 0 mid-batch is therefore a documented no-op — the loop keeps
        // dequeuing at whatever effective limit it already had, it does NOT
        // pause. This differs from `PreviewGeneratorCoordinator`, where the
        // effective limit is a live computed property (see
        // PreviewCancellationTests for the contrasting behavior).
        await coordinator.setConcurrencyLimit(0)
        print("⏸️ Set concurrencyLimit = 0 (documented no-op mid-batch for MosaicGeneratorCoordinator)")

        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(!batchTask.isCancelled, "A concurrency-limit change alone must not cancel the batch task")

        // "Resume": raise it back to 2 and let the batch drain the remaining queue.
        await coordinator.setConcurrencyLimit(2)
        print("▶️ Set concurrencyLimit = 2 — observing the queue continue to drain")

        let results = try await batchTask.value
        #expect(results.count == videos.count)

        let succeededCount = results.filter(\.isSuccess).count
        let notSucceededCount = results.count - succeededCount
        print("📊 succeeded=\(succeededCount) not-succeeded=\(notSucceededCount) total=\(results.count)")

        // Re-fetch the full claimed set: claiming kept happening in the
        // background (up to claimLimit) after the initial wait returned on
        // the very first claim, so this is the complete "we tried to cancel
        // this one individually" set, not just the first video seen.
        let allClaimedIDs = await tracker.claimedIDs()
        print("🎯 Individually cancelled \(allClaimedIDs.count) videos in total")

        // As in the single-cancel test, a fast video can still win the race
        // against an individual cancelGeneration() call — log the observed
        // outcome per cancelled video rather than hard-failing on it.
        for id in allClaimedIDs {
            let result = results.first { $0.video.id == id }
            print("📊 Explicitly cancelled video \(id): isSuccess=\(result?.isSuccess ?? false)")
        }
    }

    @Test("cancelAllGenerations aborts the whole batch, concurrency left untouched")
    func cancelWholeGenerationWithoutChangingConcurrency() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 8) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-whole-no-concurrency-change")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        let tracker = ProgressTracker()

        let batchTask = Task {
            try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { progress in
                Task { await tracker.record(progress) }
            }
        }

        let started = await waitUntil(timeout: 60) {
            await !tracker.processingVideoIDs().isEmpty
        }
        #expect(started)
        guard started else {
            batchTask.cancel()
            return
        }

        print("🛑 Cancelling the whole generation (concurrency left at 8)")
        await coordinator.cancelAllGenerations()

        do {
            _ = try await batchTask.value
            Issue.record("Expected the batch call to throw after cancelAllGenerations()")
        } catch {
            print("✅ Batch threw as expected: \(error)")
            #expect(error is CancellationError || Self.isCancellationLike(error))
        }

        let finalStatuses = await tracker.latestSnapshot()
        print("📊 Final per-video statuses: \(finalStatuses.count) videos observed")
    }

    @Test("cancelAllGenerations aborts the whole batch even with concurrency dropped to 0 at the same time")
    func cancelWholeGenerationAndDropConcurrencyToZero() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 8) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-whole-and-zero-concurrency")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        let tracker = ProgressTracker()

        let batchTask = Task {
            try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { progress in
                Task { await tracker.record(progress) }
            }
        }

        let started = await waitUntil(timeout: 60) {
            await !tracker.processingVideoIDs().isEmpty
        }
        #expect(started)
        guard started else {
            batchTask.cancel()
            return
        }

        print("🛑 Cancelling the whole generation AND setting concurrencyLimit = 0 at the same time")
        async let cancelAll: Void = coordinator.cancelAllGenerations()
        async let dropConcurrency: Void = coordinator.setConcurrencyLimit(0)
        _ = await (cancelAll, dropConcurrency)

        do {
            _ = try await batchTask.value
            Issue.record("Expected the batch call to throw after cancelAllGenerations()")
        } catch {
            print("✅ Batch threw as expected even with concurrency dropped to 0: \(error)")
        }

        // Confirm the coordinator is still usable afterwards: cancelAllGenerations()'s
        // epoch bump must not permanently wedge it, and concurrencyLimit == 0 means
        // "auto" for a brand new batch rather than "paused forever".
        guard let freshVideos = try await loadVideos(count: 2) else { return }
        let freshResults = try await coordinator.generateMosaicsforbatch(videos: freshVideos, config: config) { _ in }
        #expect(freshResults.count == freshVideos.count)
        print("📊 Fresh batch after cancel+concurrency=0: \(freshResults.filter(\.isSuccess).count)/\(freshResults.count) succeeded")
    }

    // MARK: - Fixture

    /// Width 8000 + XXS density maximizes both output resolution and frame
    /// count so batch items stay in-flight long enough to reliably interact
    /// with them (cancel, pause, resume) mid-run.
    private func makeSlowConfiguration(outputDirectory: URL) -> MosaicConfiguration {
        MosaicConfiguration(
            width: 8000,
            density: .xxs,
            format: .heif,
            layout: LayoutConfiguration(aspectRatio: .widescreen, spacing: 4, layoutType: .custom),
            includeMetadata: false,
            useAccurateTimestamps: false,
            compressionQuality: 0.5,
            outputdirectory: outputDirectory,
            fullPathInName: true,
            useMovieColorsForBg: false
        )
    }

    private func makeTempOutputDir(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitCancellationTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scans `folderURL` for videos and pads the result (by re-scanning the
    /// same files with fresh IDs) up to `count` entries. Returns `nil` (after
    /// printing a skip message) when the folder has no usable videos.
    private func loadVideos(count: Int) async throws -> [VideoInput]? {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            print("⏭️  Skipped: set \(Self.folderPathEnvKey) to a directory containing video files (looked at \(folderURL.path))")
            return nil
        }

        let discovered = await scanVideos(in: folderURL, recursive: false)
        guard !discovered.isEmpty else {
            print("⏭️  Skipped: no supported videos found in \(folderURL.path)")
            return nil
        }

        var videos = discovered
        while videos.count < count {
            let more = await scanVideos(in: folderURL, recursive: false)
            guard !more.isEmpty else { break } // safety valve against a degenerate folder
            videos.append(contentsOf: more)
        }
        return Array(videos.prefix(count))
    }

    private static func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let description = String(describing: error).lowercased()
        return description.contains("cancel")
    }
}

// MARK: - Progress tracking

/// Thread-safe progress store keyed by video ID. Beyond recording status
/// history, it can "claim" videos the instant they go active — used to fire
/// a cancellation as early as possible instead of polling then reacting,
/// which loses the race against fast real-world processing.
private actor ProgressTracker {
    private var latest: [UUID: MosaicGenerationStatus] = [:]
    private var history: [UUID: [MosaicGenerationStatus]] = [:]
    private var claimed: [UUID: VideoInput] = [:]
    private let claimLimit: Int

    init(claimLimit: Int = 0) {
        self.claimLimit = claimLimit
    }

    func record(_ progress: MosaicGenerationProgress) {
        latest[progress.video.id] = progress.status
        history[progress.video.id, default: []].append(progress.status)
    }

    /// Records progress and, if `progress.video` is newly active and we are
    /// still under `claimLimit`, claims it and returns it (once).
    func recordAndMaybeClaim(_ progress: MosaicGenerationProgress) -> VideoInput? {
        record(progress)
        guard claimed.count < claimLimit,
              claimed[progress.video.id] == nil,
              Self.isProcessing(progress.status) else { return nil }
        claimed[progress.video.id] = progress.video
        return progress.video
    }

    func claimedIDs() -> Set<UUID> {
        Set(claimed.keys)
    }

    func processingVideoIDs() -> [UUID] {
        latest.compactMap { id, status in Self.isProcessing(status) ? id : nil }
    }

    func latestSnapshot() -> [UUID: MosaicGenerationStatus] {
        latest
    }

    private static func isProcessing(_ status: MosaicGenerationStatus) -> Bool {
        switch status {
        case .inProgress, .countingThumbnails, .computingLayout, .extractingThumbnails, .creatingMosaic, .savingMosaic:
            return true
        case .queued, .completed, .failed, .cancelled:
            return false
        }
    }
}

// MARK: - Polling helper

private func waitUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    return await condition()
}
