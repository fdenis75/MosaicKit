import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "com.mosaicKit", category: "ExportWatchdog")

/// Stall and cancellation watchdog shared by the preview export paths: native
/// (`AVAssetExportSession`), SJS and the ffmpeg-mode passthrough (plan step S-4).
///
/// It polls on a `DispatchSourceTimer` on its own serial queue, not in a Swift `Task`. When the
/// cooperative pool is saturated by other generations, `Task.sleep` polling wakes up seconds
/// late; the ffmpeg watchdog was fixed the same way in #34 (I-16).
///
/// On the first tick where the caller has asked to cancel, or where `progress` has not moved for
/// `stallTimeout`, it records the reason and calls `stop` exactly once, then stops ticking.
/// After the export returns, `failure(error:outputURL:failedMessage:missingOutputMessage:)` maps
/// how it ended to the error to throw.
final class ExportWatchdog: @unchecked Sendable {
    // @unchecked: `timer` is only resumed in `init` and cancelled (an idempotent, thread-safe
    // call) afterwards; all mutable state is behind `firedReason`'s mutex.

    /// Why the watchdog stopped an export.
    enum Reason: Sendable, Equatable {
        case cancelled
        case stalled
    }

    /// Default stall budget. macOS doubles it because a backgrounded process can legitimately
    /// pause for more than 60 s before its activity assertion resumes it.
    #if os(macOS)
    static let defaultStallTimeout: TimeInterval = 120
    #else
    static let defaultStallTimeout: TimeInterval = 60
    #endif

    let progress: ExportProgressTracker
    private let label: String
    private let stallTimeout: TimeInterval
    private let isCancellationRequested: @Sendable () -> Bool
    private let stop: @Sendable (Reason) -> Void
    private let timer: any DispatchSourceTimer
    private let firedReason = Mutex<Reason?>(nil)

    /// Creates and starts the watchdog.
    /// - Parameters:
    ///   - label: Export path name, used in logs and the queue label.
    ///   - progress: The tracker the export's progress monitor records into.
    ///   - stallTimeout: Seconds without progress before the export counts as stalled.
    ///   - interval: Polling interval.
    ///   - isCancellationRequested: The caller's cancellation check (the generation's token).
    ///   - stop: Cancels the export. Called at most once, on the watchdog queue.
    init(
        label: String,
        progress: ExportProgressTracker,
        stallTimeout: TimeInterval = ExportWatchdog.defaultStallTimeout,
        interval: DispatchTimeInterval = .milliseconds(500),
        isCancellationRequested: @escaping @Sendable () -> Bool,
        stop: @escaping @Sendable (Reason) -> Void
    ) {
        self.label = label
        self.progress = progress
        self.stallTimeout = stallTimeout
        self.isCancellationRequested = isCancellationRequested
        self.stop = stop
        let queue = DispatchQueue(label: "com.mosaicKit.preview.watchdog.\(label)", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// Stops polling. Safe to call more than once; call it as soon as the export returns.
    func invalidate() { timer.cancel() }

    /// Whether the watchdog stopped the export because it made no progress.
    var didStall: Bool { firedReason.withLock { $0 == .stalled } }

    /// Why the watchdog stopped the export, if it did.
    var reason: Reason? { firedReason.withLock { $0 } }

    private func tick() {
        let reason: Reason
        let idle = progress.secondsSinceLastProgress
        if isCancellationRequested() {
            reason = .cancelled
        } else if idle >= stallTimeout {
            reason = .stalled
        } else {
            return
        }
        let isFirst = firedReason.withLock { fired -> Bool in
            guard fired == nil else { return false }
            fired = reason
            return true
        }
        guard isFirst else { return }
        timer.cancel()
        switch reason {
        case .cancelled:
            logger.warning("Cancellation requested, cancelling \(self.label, privacy: .public) export")
        case .stalled:
            logger.error("\(self.label, privacy: .public) export stalled: no progress for \(Int(idle))s at \(Int(self.progress.lastValue * 100))%, cancelling")
        }
        stop(reason)
    }

    /// The error to throw for how the export ended, or `nil` when it succeeded.
    ///
    /// Checked in priority order: the watchdog's stall, cancellation (the caller's check or a
    /// `CancellationError`), the export's own error, then a missing output file.
    func failure(error: Error?, outputURL: URL, failedMessage: String, missingOutputMessage: String) -> PreviewError? {
        Self.failure(
            error: error,
            stalledSeconds: didStall ? Int(progress.secondsSinceLastProgress) : nil,
            cancelled: reason == .cancelled || isCancellationRequested(),
            outputExists: FileManager.default.fileExists(atPath: outputURL.path),
            failedMessage: failedMessage,
            missingOutputMessage: missingOutputMessage
        )
    }

    /// The outcome mapping itself, separated so it can be tested without an export.
    static func failure(
        error: Error?,
        stalledSeconds: Int?,
        cancelled: Bool,
        outputExists: Bool,
        failedMessage: String,
        missingOutputMessage: String
    ) -> PreviewError? {
        if let stalledSeconds { return .exportStalled(elapsedSeconds: stalledSeconds) }
        if cancelled || error is CancellationError { return .cancelled }
        if let error { return .encodingFailed(failedMessage, error) }
        if !outputExists { return .encodingFailed(missingOutputMessage, nil) }
        return nil
    }
}
