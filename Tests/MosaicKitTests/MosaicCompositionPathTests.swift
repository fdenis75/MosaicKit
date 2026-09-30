import Foundation
import CoreGraphics
import ImageIO
import Synchronization
import Testing
@testable import MosaicKit

/// `generate(for:config:forIphone:)` and `generateMosaicImage(for:config:forIphone:)` share one
/// composition path (plan step S-2). These checks keep them equivalent: the same video and
/// configuration must give a mosaic of the same size, whether it is saved or returned in memory.
struct MosaicCompositionPathTests {

    @Test("In-memory and saved mosaics of the same video have the same size")
    func inMemoryMatchesSavedMosaic() async throws {
        let videoURL = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"),
                                    "Missing test fixture test_video.mp4")
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitCompositionPath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // Small and sparse for speed, with every overlay on so both paths run every stage.
        var config = MosaicConfiguration(
            width: 1600,
            density: .xxl,
            format: .jpeg,
            layout: LayoutConfiguration(aspectRatio: .widescreen, layoutType: .custom),
            includeMetadata: true,
            useAccurateTimestamps: false,
            compressionQuality: 0.5,
            outputdirectory: outputDir
        )
        config.overwrite = true
        config.gifMode = .disabled
        config.overlay.watermark = WatermarkConfig(content: .text("S-2"), position: .bottomRight, opacity: 0.5, scale: 0.1)
        config.overlay.colorDNA = ColorDNAConfig(show: true, height: 16, position: .bottom, style: .barcode)

        let generator = try MetalMosaicGenerator()
        let savedURL = try await generator.generate(for: video, config: config)

        let statuses = StatusLog()
        await generator.setProgressHandler(for: video) { statuses.append($0.status) }
        let image = try await generator.generateMosaicImage(for: video, config: config)

        let source = try #require(CGImageSourceCreateWithURL(savedURL as CFURL, nil), "Cannot read \(savedURL.lastPathComponent)")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let savedWidth = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let savedHeight = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(image.width == savedWidth, "In-memory width \(image.width), saved \(savedWidth)")
        #expect(image.height == savedHeight, "In-memory height \(image.height), saved \(savedHeight)")
        #expect(statuses.last == .completed)
    }
}

private final class StatusLog: Sendable {
    private let statuses = Mutex<[MosaicGenerationStatus]>([])
    func append(_ status: MosaicGenerationStatus) { statuses.withLock { $0.append(status) } }
    var last: MosaicGenerationStatus? { statuses.withLock { $0.last } }
}
