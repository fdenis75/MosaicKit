import Foundation
import AVFoundation
import Synchronization
import Testing
@testable import MosaicKit

/// End-to-end preview export smoke test (implementation plan P-2b).
///
/// Before this suite, no preview export ran in CI at all (knowledge base rules card #14): the
/// other preview tests cover configuration, clip maths and process handling only. This runs
/// the real pipeline once — inspect, pick extracts, compose, export with `AVAssetExportSession`
/// — on the embedded fixture, so the shared export code that plan step S-4 refactors has a
/// regression net on both CI platforms.
///
/// It uses an H.264 preset (`AVAssetExportPresetMediumQuality`) because it is fast and
/// available on the iOS Simulator; HEVC export there is slow software encoding.
///
/// On failure the test reports the full progress trail (status, progress and exporter message,
/// timestamped), so an export that stalls shows which state it was stuck in.
///
/// I-26: under macOS background scheduling or a background QoS clamp the export can stall
/// mid-encode for minutes. On the CI virtual machine it also stalls with normal scheduling
/// (1 run in 10–30); that one case is recorded as a known issue, see the `catch` below. The
/// test leaves darwin background scheduling first and logs the scheduling state (including the
/// main thread's QoS, which shows a clamp) so a CI stall can be attributed. The library itself never changes
/// its host's scheduling; apps handle this as described in the `PreviewExporting` article.
struct PreviewExportSmokeTests {

    @Test("Native preview export produces a playable movie from the embedded video")
    func nativePreviewExportProducesMovie() async throws {
        let wasBackground = ProcessScheduling.leaveBackground()
        let scheduling = await ProcessScheduling.diagnostics()
        print("PreviewExportSmokeTests: left darwin background scheduling: \(wasBackground); \(scheduling)")
        let videoURL = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"),
                                    "Missing test fixture test_video.mp4")
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitPreviewSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        var config = PreviewConfiguration(
            targetDuration: 10,
            density: .xxl,
            format: .mp4,
            includeAudio: false,
            outputDirectory: outputDir,
            exportMode: .native,
            exportPresetName: .AVAssetExportPresetMediumQuality,
            enableAppLifecycleMonitor: false,
            enableExportRetry: false
        )
        config.overwrite = true

        let trail = ProgressTrail()
        let generator = PreviewVideoGenerator()
        await generator.setProgressHandler(for: video) { trail.append($0) }

        let outputURL: URL
        do {
            outputURL = try await generator.generate(for: video, config: config)
        } catch {
            let report = "Preview export failed: \(error)\nLeft darwin background scheduling at start: \(wasBackground). At start: \(scheduling). Now: \(await ProcessScheduling.diagnostics())\nProgress trail:\n\(trail.formatted)"
            // I-26: on the CI virtual machine the native export intermittently freezes mid-encode
            // (always at 60 %) with normal scheduling; a utility QoS cap alone does not reproduce
            // it on real hardware. Only that stall, and only on a VM, is a known issue. On real
            // Macs, and for any other error, the test fails.
            if case PreviewError.exportStalled = error, ProcessScheduling.isVirtualMachine {
                withKnownIssue("I-26: native export stall on a virtual machine", isIntermittent: true) {
                    Issue.record(Comment(rawValue: report))
                }
            } else {
                Issue.record(Comment(rawValue: report))
            }
            return
        }

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        #expect(size > 0)

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0, "Exported preview has no duration")
        // Smoke-level bound only; exact clip maths is covered by PreviewConfigurationTests.
        #expect(duration <= config.targetDuration * 1.5, "Preview is \(duration) s for a \(config.targetDuration) s target")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty, "Exported preview has no video track")
    }
}

/// Timestamped record of every progress update, for failure diagnostics.
private final class ProgressTrail: Sendable {
    private let start = ContinuousClock.now
    private let lines = Mutex<[String]>([])

    func append(_ progress: PreviewGenerationProgress) {
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let line = "+\(String(format: "%6.1f", seconds))s  \(progress.status)  "
            + "\(String(format: "%3.0f", progress.progress * 100))%  \(progress.message ?? "")"
        lines.withLock { $0.append(line) }
    }

    var formatted: String {
        lines.withLock { $0.isEmpty ? "(no progress reported)" : $0.joined(separator: "\n") }
    }
}
