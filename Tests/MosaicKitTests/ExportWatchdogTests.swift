import Foundation
import Synchronization
import Testing
@testable import MosaicKit

/// The shared preview export watchdog and outcome mapper (plan step S-4).
///
/// Short timeouts and a 20 ms polling interval keep each case well under a second.
struct ExportWatchdogTests {

    @Test("A stalled export is stopped once, with .stalled, and maps to exportStalled")
    func stallStopsExportOnce() async throws {
        let stops = StopLog()
        let watchdog = ExportWatchdog(label: "test", progress: makeTracker(), stallTimeout: 0.2,
                                      interval: .milliseconds(20),
                                      isCancellationRequested: { false }) { stops.record($0) }
        defer { watchdog.invalidate() }

        try await waitUntil { stops.count > 0 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(stops.reasons == [.stalled], "stop must be called exactly once")
        #expect(watchdog.didStall)
        let failure = watchdog.failure(error: nil, outputURL: missingURL, failedMessage: "f", missingOutputMessage: "m")
        guard case .exportStalled = failure else {
            Issue.record("Expected exportStalled, got \(String(describing: failure))")
            return
        }
    }

    @Test("A cancellation request stops the export with .cancelled and maps to cancelled")
    func cancellationStopsExport() async throws {
        let stops = StopLog()
        let cancelled = Flag()
        let watchdog = ExportWatchdog(label: "test", progress: makeTracker(), stallTimeout: 60,
                                      interval: .milliseconds(20),
                                      isCancellationRequested: { cancelled.value }) { stops.record($0) }
        defer { watchdog.invalidate() }

        try await Task.sleep(for: .milliseconds(100))
        #expect(stops.reasons.isEmpty, "Nothing to stop before cancellation is requested")

        cancelled.set()
        try await waitUntil { stops.count > 0 }

        #expect(stops.reasons == [.cancelled])
        #expect(!watchdog.didStall)
        let failure = watchdog.failure(error: nil, outputURL: missingURL, failedMessage: "f", missingOutputMessage: "m")
        guard case .cancelled = failure else {
            Issue.record("Expected cancelled, got \(String(describing: failure))")
            return
        }
    }

    @Test("Steady progress keeps an export alive past its stall timeout")
    func progressKeepsExportAlive() async throws {
        let stops = StopLog()
        let tracker = makeTracker()
        let watchdog = ExportWatchdog(label: "test", progress: tracker, stallTimeout: 0.3,
                                      interval: .milliseconds(20),
                                      isCancellationRequested: { false }) { stops.record($0) }
        defer { watchdog.invalidate() }

        // Progress arrives every 30 ms from a dispatch timer, as AVFoundation delivers it. A
        // Task.sleep loop would be starved when the full suite saturates the cooperative pool,
        // and the watchdog (on its own queue) would then rightly report a stall.
        let steps = Counter()
        let feeder = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ExportWatchdogTests.feeder"))
        feeder.schedule(deadline: .now(), repeating: .milliseconds(30))
        feeder.setEventHandler {
            tracker.recordProgress(Double(steps.next()) / 1000)
        }
        feeder.resume()
        defer { feeder.cancel() }

        try await Task.sleep(for: .seconds(1))

        #expect(stops.reasons.isEmpty, "1 s of steady progress must not count as a 0.3 s stall")
        #expect(tracker.lastValue > 0)
    }

    @Test("After invalidate, a stalled export is not stopped")
    func invalidateStopsPolling() async throws {
        let stops = StopLog()
        let watchdog = ExportWatchdog(label: "test", progress: makeTracker(), stallTimeout: 0.1,
                                      interval: .milliseconds(20),
                                      isCancellationRequested: { false }) { stops.record($0) }
        watchdog.invalidate()
        try await Task.sleep(for: .milliseconds(300))
        #expect(stops.reasons.isEmpty)
    }

    @Test("Outcome mapping order: stall, cancellation, export error, missing output, success")
    func outcomeMappingOrder() {
        struct ExportFailed: Error {}
        func map(_ error: Error?, stalled: Int? = nil, cancelled: Bool = false, exists: Bool = true) -> PreviewError? {
            ExportWatchdog.failure(error: error, stalledSeconds: stalled, cancelled: cancelled, outputExists: exists,
                                   failedMessage: "failed", missingOutputMessage: "missing")
        }

        guard case .exportStalled(let seconds)? = map(ExportFailed(), stalled: 7, cancelled: true, exists: false) else {
            Issue.record("A stall wins over everything"); return
        }
        #expect(seconds == 7)
        guard case .cancelled? = map(ExportFailed(), cancelled: true) else {
            Issue.record("Cancellation wins over the export error"); return
        }
        guard case .cancelled? = map(CancellationError()) else {
            Issue.record("A CancellationError is reported as cancelled, not failed"); return
        }
        guard case .encodingFailed(let message, let underlying)? = map(ExportFailed(), exists: false) else {
            Issue.record("An export error maps to encodingFailed"); return
        }
        #expect(message == "failed")
        #expect(underlying is ExportFailed)
        guard case .encodingFailed(let missingMessage, nil)? = map(nil, exists: false) else {
            Issue.record("A missing output maps to encodingFailed without an underlying error"); return
        }
        #expect(missingMessage == "missing")
        #expect(map(nil) == nil, "Success maps to nil")
    }

    // MARK: - Helpers

    private var missingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ExportWatchdogTests-\(UUID().uuidString).mov")
    }

    private func makeTracker() -> ExportProgressTracker {
        let tracker = ExportProgressTracker()
        tracker.recordProgress(0)
        return tracker
    }

    /// Polls `condition` every 10 ms for up to 5 s.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the watchdog")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class StopLog: Sendable {
    private let storage = Mutex<[ExportWatchdog.Reason]>([])
    func record(_ reason: ExportWatchdog.Reason) { storage.withLock { $0.append(reason) } }
    var reasons: [ExportWatchdog.Reason] { storage.withLock { $0 } }
    var count: Int { storage.withLock { $0.count } }
}

private final class Counter: Sendable {
    private let storage = Mutex(0)
    func next() -> Int { storage.withLock { $0 += 1; return $0 } }
}

private final class Flag: Sendable {
    private let storage = Mutex<Bool>(false)
    func set() { storage.withLock { $0 = true } }
    var value: Bool { storage.withLock { $0 } }
}
