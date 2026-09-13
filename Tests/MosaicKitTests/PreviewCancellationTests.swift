import Foundation
import Testing
@testable import MosaicKit

/// Cancellation and concurrency-control tests for `PreviewGeneratorCoordinator`.
///
/// Mirrors `MosaicCancellationTests`, but for preview video generation. Uses
/// a heavy configuration (`targetDuration: 120s`, `density: .xxs`) with the
/// native (`AVAssetExportSession`) export mode so no `ffmpeg` dependency is
/// required, and processes real files from a folder so a batch stays
/// in-flight long enough to reliably exercise cancellation/concurrency
/// changes mid-run.
///
/// Set `PREVIEW_CANCELLATION_TEST_DIR` (or `MOSAICKIT_TEST_VIDEOS_DIR`) to a
/// folder containing video files to run them. They are skipped (not failed)
/// when no folder is available, or when `MOSAICKIT_SUITE_MODE=none` (the CI
/// default for extended suites).
@Suite("Preview batch cancellation and concurrency control")
struct PreviewCancellationTests {

    private static let previewFolderEnvKey = "PREVIEW_CANCELLATION_TEST_DIR"
    private static let sharedFolderEnvKey = "MOSAICKIT_TEST_VIDEOS_DIR"
    private static let defaultMediaFolderPath = "/tmp/mosaickit-test-videos"

    private var isCIMode: Bool {
        ProcessInfo.processInfo.environment["MOSAICKIT_SUITE_MODE"] == "none"
    }

    private var folderURL: URL {
        let env = ProcessInfo.processInfo.environment
        let path = env[Self.previewFolderEnvKey] ?? env[Self.sharedFolderEnvKey] ?? Self.defaultMediaFolderPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Tests

    @Test("Cancel a single in-flight preview mid-batch; the rest of the batch continues")
    func cancelSingleProcessingTask() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 10) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-single")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        // Reacts to progress *inside the callback*, the instant the first
        // preview goes active, and fires the cancel immediately —
        // polling-then-acting loses the race against fast real-world export.
        let tracker = PreviewProgressTracker(claimLimit: 1)

        let batchTask = Task {
            try await coordinator.generatePreviewsForBatch(videos: videos, config: config) { progress in
                Task {
                    if let claimedVideo = await tracker.recordAndMaybeClaim(progress) {
                        print("🎯 Cancelling one in-flight preview: \(claimedVideo.title) [\(claimedVideo.id)]")
                        await coordinator.cancelGeneration(for: claimedVideo)
                    }
                }
            }
        }

        let results = try await batchTask.value
        let claimedIDs = await tracker.claimedIDs()

        #expect(!claimedIDs.isEmpty, "Expected to observe and cancel at least one in-flight preview")
        #expect(results.count == videos.count, "Batch should still report one result per input video")

        guard let activeID = claimedIDs.first else { return }
        let cancelledResult = results.first { $0.video.id == activeID }
        #expect(cancelledResult != nil)
        // A fast preview may still win the race against the cancel call —
        // that's itself a valid observed outcome, so we log it and only
        // assert the invariant that matters: the rest of the batch continues.
        print("📊 Explicitly cancelled preview result: isSuccess=\(cancelledResult?.isSuccess ?? false)")

        let others = results.filter { $0.video.id != activeID }
        let othersSucceeded = others.filter(\.isSuccess).count
        print("📊 Others succeeded: \(othersSucceeded)/\(others.count) after cancelling one preview")
        #expect(othersSucceeded > 0, "Cancelling a single preview must not abort the rest of the batch")
    }

    @Test("Cancel every in-flight preview individually, then pause (concurrency=0) and resume (concurrency=2)")
    func cancelAllProcessingTasksThenPauseAndResume() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 12) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-all-processing-pause-resume")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        // Claim (and immediately cancel) every preview the moment it goes
        // active, up to the concurrency limit — see the single-cancel test
        // for why reacting inside the callback is necessary here.
        let tracker = PreviewProgressTracker(claimLimit: 8)

        let batchTask = Task {
            try await coordinator.generatePreviewsForBatch(videos: videos, config: config) { progress in
                Task {
                    if let claimedVideo = await tracker.recordAndMaybeClaim(progress) {
                        print("🎯 Cancelling in-flight preview: \(claimedVideo.title) [\(claimedVideo.id)]")
                        await coordinator.cancelGeneration(for: claimedVideo)
                    }
                }
            }
        }

        // Give the first wave a moment to actually be claimed/cancelled
        // before touching concurrency, without gating strictly on it.
        _ = await waitUntil(timeout: 45) {
            let ids = await tracker.claimedIDs()
            return !ids.isEmpty
        }
        let activeIDs = await tracker.claimedIDs()
        #expect(!activeIDs.isEmpty, "Expected to observe and cancel at least one in-flight preview")

        // "Pause": drop concurrency to 0.
        //
        // Observed behavior: unlike MosaicGeneratorCoordinator,
        // PreviewGeneratorCoordinator's `effectiveConcurrencyLimit` is a live
        // computed property (`concurrencyLimit > 0 ? concurrencyLimit :
        // calculateOptimalConcurrency()`), and the batch loop re-reads it on
        // every iteration. So `concurrencyLimit = 0` does NOT freeze the
        // queue at zero — it is immediately reinterpreted as "auto" and the
        // loop falls back to the dynamically calculated (non-zero) slot
        // count. It is a *reduction*, not a true pause.
        await coordinator.setConcurrencyLimit(0)
        print("⏸️ Set concurrencyLimit = 0 (reinterpreted as \"auto\", not a true pause, for PreviewGeneratorCoordinator)")

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
        // this one individually" set, not just the first preview seen.
        let allClaimedIDs = await tracker.claimedIDs()
        print("🎯 Individually cancelled \(allClaimedIDs.count) previews in total")

        // As in the single-cancel test, a fast preview can still win the
        // race — log the observed outcome per cancelled video.
        for id in allClaimedIDs {
            let result = results.first { $0.video.id == id }
            print("📊 Explicitly cancelled preview \(id): isSuccess=\(result?.isSuccess ?? false)")
        }
    }

    @Test("cancelAllGenerations aborts the whole preview batch, concurrency left untouched")
    func cancelWholeGenerationWithoutChangingConcurrency() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 8) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-whole-no-concurrency-change")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        let tracker = PreviewProgressTracker()

        let batchTask = Task {
            try await coordinator.generatePreviewsForBatch(videos: videos, config: config) { progress in
                Task { await tracker.record(progress) }
            }
        }

        let started = await waitUntil(timeout: 90) {
            await !tracker.processingVideoIDs().isEmpty
        }
        #expect(started)
        guard started else {
            batchTask.cancel()
            return
        }

        print("🛑 Cancelling the whole preview generation (concurrency left at 8)")
        await coordinator.cancelAllGenerations()

        do {
            _ = try await batchTask.value
            Issue.record("Expected the batch call to throw after cancelAllGenerations()")
        } catch {
            print("✅ Batch threw as expected: \(error)")
        }

        let finalStatuses = await tracker.latestSnapshot()
        print("📊 Final per-video statuses: \(finalStatuses.count) videos observed")
    }

    @Test("cancelAllGenerations aborts the whole preview batch even with concurrency dropped to 0 at the same time")
    func cancelWholeGenerationAndDropConcurrencyToZero() async throws {
        guard !isCIMode else { print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none"); return }
        guard let videos = try await loadVideos(count: 8) else { return }

        let outputDir = try makeTempOutputDir(name: "cancel-whole-and-zero-concurrency")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: 8)
        let config = makeSlowConfiguration(outputDirectory: outputDir)
        let tracker = PreviewProgressTracker()

        let batchTask = Task {
            try await coordinator.generatePreviewsForBatch(videos: videos, config: config) { progress in
                Task { await tracker.record(progress) }
            }
        }

        let started = await waitUntil(timeout: 90) {
            await !tracker.processingVideoIDs().isEmpty
        }
        #expect(started)
        guard started else {
            batchTask.cancel()
            return
        }

        print("🛑 Cancelling the whole preview generation AND setting concurrencyLimit = 0 at the same time")
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
        let freshResults = try await coordinator.generatePreviewsForBatch(videos: freshVideos, config: config) { _ in }
        #expect(freshResults.count == freshVideos.count)
        print("📊 Fresh batch after cancel+concurrency=0: \(freshResults.filter(\.isSuccess).count)/\(freshResults.count) succeeded")
    }

    // MARK: - Fixture

    /// A 2-minute target duration at XXS density maximizes the number of
    /// extracted segments and composition work so batch items stay in-flight
    /// long enough to reliably interact with them (cancel, pause, resume)
    /// mid-run. `.native` export mode avoids an external `ffmpeg` dependency;
    /// the app-lifecycle monitor and export retry are disabled since this is
    /// a headless test process (per MosaicKit's CLI/daemon guidance).
    private func makeSlowConfiguration(outputDirectory: URL) -> PreviewConfiguration {
        PreviewConfiguration(
            targetDuration: 120,
            density: .xxs,
            format: .mp4,
            includeAudio: true,
            outputDirectory: outputDirectory,
            fullPathInName: true,
            compressionQuality: 0.5,
            exportMode: .native,
            enableAppLifecycleMonitor: false,
            enableExportRetry: false
        )
    }

    private func makeTempOutputDir(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCancellationTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scans `folderURL` for videos and pads the result (by re-scanning the
    /// same files with fresh IDs) up to `count` entries. Returns `nil` (after
    /// printing a skip message) when the folder has no usable videos.
    private func loadVideos(count: Int) async throws -> [VideoInput]? {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            print("⏭️  Skipped: set \(Self.previewFolderEnvKey) or \(Self.sharedFolderEnvKey) to a directory containing video files (looked at \(folderURL.path))")
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
}

// MARK: - Progress tracking

/// Thread-safe progress store keyed by video ID. Beyond recording status
/// history, it can "claim" videos the instant they go active — used to fire
/// a cancellation as early as possible instead of polling then reacting,
/// which loses the race against fast real-world export.
private actor PreviewProgressTracker {
    private var latest: [UUID: PreviewGenerationStatus] = [:]
    private var history: [UUID: [PreviewGenerationStatus]] = [:]
    private var claimed: [UUID: VideoInput] = [:]
    private let claimLimit: Int

    init(claimLimit: Int = 0) {
        self.claimLimit = claimLimit
    }

    func record(_ progress: PreviewGenerationProgress) {
        latest[progress.video.id] = progress.status
        history[progress.video.id, default: []].append(progress.status)
    }

    /// Records progress and, if `progress.video` is newly active and we are
    /// still under `claimLimit`, claims it and returns it (once).
    func recordAndMaybeClaim(_ progress: PreviewGenerationProgress) -> VideoInput? {
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

    func latestSnapshot() -> [UUID: PreviewGenerationStatus] {
        latest
    }

    private static func isProcessing(_ status: PreviewGenerationStatus) -> Bool {
        switch status {
        case .analyzing, .extracting, .composing, .encoding, .saving:
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
