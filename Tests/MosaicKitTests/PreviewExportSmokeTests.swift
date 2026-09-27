import Foundation
import AVFoundation
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
struct PreviewExportSmokeTests {

    @Test("Native preview export produces a playable movie from the embedded video")
    func nativePreviewExportProducesMovie() async throws {
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

        let outputURL = try await PreviewVideoGenerator().generate(for: video, config: config)

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
