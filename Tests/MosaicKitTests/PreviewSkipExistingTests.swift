import Foundation
import Testing
@testable import MosaicKit

/// With `overwrite == false`, a preview whose default name already exists is skipped (I-12).
///
/// The default preview name used to carry a run timestamp, so the existence check could never
/// match a previous run. It is deterministic now; this proves the skip path end to end without
/// exporting anything.
struct PreviewSkipExistingTests {

    @Test("Existing preview at the default name is returned without exporting")
    func existingPreviewIsSkipped() async throws {
        let videoURL = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"),
                                    "Missing test fixture test_video.mp4")
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitPreviewSkip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        var config = PreviewConfiguration(
            targetDuration: 10,
            density: .xxl,
            format: .mp4,
            includeAudio: false,
            outputDirectory: outputDir,
            enableAppLifecycleMonitor: false,
            enableExportRetry: false
        )
        config.overwrite = false

        let existing = outputDir.appendingPathComponent(config.generateFilename(for: video))
        let marker = Data("existing preview".utf8)
        try marker.write(to: existing)

        let result = try await PreviewVideoGenerator().generate(for: video, config: config)

        #expect(result == existing)
        #expect(try Data(contentsOf: existing) == marker, "The existing file must not be touched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDir.path).count == 1)
    }
}
