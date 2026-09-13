import Foundation
import Testing
import Synchronization
@testable import MosaicKit

struct PreviewReliabilityRegressionTests {
    @Test func lateProgressCannotFollowTerminalDelivery() {
        let source = VideoInput(canonicalID: UUID(), url: URL(fileURLWithPath: "unused.mov"))
        let statuses = Mutex<[PreviewGenerationStatus]>([])
        let delivery = PreviewProgressDelivery { event in statuses.withLock { $0.append(event.status) } }
        delivery.send(PreviewGenerationProgress(video: source, progress: 0.5, status: .encoding))
        delivery.send(PreviewGenerationProgress(video: source, progress: 1, status: .completed))
        delivery.send(PreviewGenerationProgress(video: source, progress: 0.7, status: .encoding))
        delivery.send(.cancelled(for: source))
        #expect(statuses.withLock { $0 } == [.encoding, .completed])
    }

    @Test func fractionalFrameRateIsPreserved() {
        let duration = PreviewGenerationLogic.frameDuration(for: 29.97).seconds
        #expect(abs(duration - 1 / 29.97) < 0.000002)
        #expect(PreviewGenerationLogic.frameDuration(for: .nan).seconds > 0)
        #expect(PreviewGenerationLogic.frameDuration(for: .infinity).seconds > 0)
    }

    #if os(macOS)
    @Test func ffmpegReportsBoundedDiagnostics() async throws {
        do {
            try await FFmpegEncoder.runFFmpeg(binaryPath: "/bin/sh", arguments: ["-c", "echo diagnostic-marker >&2; exit 7"], totalDuration: 1, progressHandler: { _, _ in }, cancellationCheck: { false })
            Issue.record("Expected process failure")
        } catch PreviewError.ffmpegEncodingFailed(let code, let output) {
            #expect(code == 7)
            #expect(output.utf8.count <= 32768)
        }
    }

    @Test func ffmpegCancellationKillsUncooperativeProcess() async throws {
        let token = CancellationToken()
        let start = ContinuousClock.now
        do {
            try await FFmpegEncoder.runFFmpeg(
                binaryPath: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo 'time=00:00:00.10' >&2; while :; do :; done"],
                totalDuration: 1,
                progressHandler: { _, _ in token.cancel() },
                cancellationCheck: { token.isCancelled }
            )
            Issue.record("Expected cancellation")
        } catch PreviewError.cancelled {
            #expect(start.duration(to: .now) < .seconds(8))
        }
    }
    #endif
}
