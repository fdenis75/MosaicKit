import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import MosaicKit

@Suite("Mosaic pipeline reliability")
struct MosaicPipelineReliabilityTests {
    @Test("Nonfinite and out-of-range layout inputs fail without conversion traps")
    func invalidLayoutInputs() {
        let processor = LayoutProcessor()
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            #expect(processor.calculateThumbnailCount(duration: duration, width: 1000, density: .m, videoAR: 1) == 0)
        }
        let layout = processor.calculateLayout(originalAspectRatio: .nan, mosaicAspectRatio: .widescreen,
            thumbnailCount: 10, mosaicWidth: 1000, density: .m, layoutType: .classic)
        #expect(layout.positions.isEmpty)
    }

    @Test("Layout cache includes target aspect ratio")
    func cacheIncludesAspectRatio() {
        let processor = LayoutProcessor()
        let first = processor.calculateLayout(originalAspectRatio: 16.0 / 9.0, mosaicAspectRatio: .widescreen,
            thumbnailCount: 30, mosaicWidth: 1000, density: .m, layoutType: .classic)
        let second = processor.calculateLayout(originalAspectRatio: 16.0 / 9.0, mosaicAspectRatio: .square,
            thumbnailCount: 30, mosaicWidth: 1000, density: .m, layoutType: .classic)
        #expect(first.mosaicSize != second.mosaicSize)
    }

    @Test("Animation no-overwrite preserves the previous artifact")
    func animationNoOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("result.gif")
        let previous = Data("previous artifact".utf8)
        try previous.write(to: url)
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try #require(context.makeImage())
        #expect(throws: (any Error).self) {
            try AnimatedGifGenerator.save(frames: [frame], to: url, overwrite: false)
        }
        #expect(try Data(contentsOf: url) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["result.gif"])
    }

    @Test("Invalid animation input cannot replace an existing output")
    func invalidAnimation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        let data = Data("preserved".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try AnimatedGifGenerator.save(frames: [], to: url) }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("A missing frame fails instead of publishing a partial mosaic")
    func incompleteStreamFails() async throws {
        let processor = try MetalImageProcessor()
        let layout = MosaicLayout(rows: 1, cols: 1, thumbnailSize: CGSize(width: 16, height: 16),
            positions: [(x: 0, y: 0)], thumbCount: 1, thumbnailSizes: [CGSize(width: 16, height: 16)],
            mosaicSize: CGSize(width: 16, height: 16))
        let stream = AsyncThrowingStream<(Int, CGImage), Error>(unfolding: { nil })
        do {
            _ = try await processor.generateMosaicStream(stream: stream, layout: layout,
                metadata: VideoMetadata(), config: .default)
            Issue.record("Incomplete stream unexpectedly produced a mosaic")
        } catch is CancellationError {
            Issue.record("Missing frames should be a processing error")
        } catch { }
    }
}
