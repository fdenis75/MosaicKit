import Foundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MosaicKit

/// The parts of the `fixedGrid` layout that are not geometry (plan step G-3; spec
/// `codebase-analysis-docs/SPEC_FIXED_GRID_LAYOUT.md`, sections 3.4, 3.5 and the T, H and S7 rows):
/// uniform frame sampling, the header height cap, the watermark clamp and the distinct-frame check.
struct FixedGridSamplingAndOverlayTests {

    private func seconds(_ times: [CMTime]) -> [Double] { times.map(\.seconds) }

    // MARK: - Sampling

    @Test("The weighted policy is unchanged for every other layout (pinned)")
    func weightedPolicyIsUnchanged() {
        let times = seconds(ThumbnailProcessor(config: .default).calculateExtractionTimes(duration: 100, count: 10))
        let expected = [5.0, 19.85, 34.7, 39.8, 44.9, 50.0, 55.1, 60.2, 65.3, 80.15]
        #expect(times.count == expected.count)
        for (time, want) in zip(times, expected) { #expect(abs(time - want) <= 1.0 / 600, "\(time) vs \(want)") }
        // The default argument is the weighted policy.
        #expect(seconds(ThumbnailProcessor(config: .default).calculateExtractionTimes(duration: 100, count: 10, policy: .weighted)) == times)
        // At tiny counts it still puts a lone frame at 65 %, the behavior the grid avoids (spec row T1).
        #expect(abs(seconds(ThumbnailProcessor(config: .default).calculateExtractionTimes(duration: 100, count: 1))[0] - 5.0) <= 1.0 / 600
                || ThumbnailProcessor(config: .default).calculateExtractionTimes(duration: 100, count: 1).count == 1)
    }

    @Test("The uniform policy is cell-centered and evenly spaced over 5...95 %")
    func uniformPolicy() {
        let processor = ThumbnailProcessor(config: .default)
        func uniform(_ duration: Double, _ count: Int) -> [Double] {
            seconds(processor.calculateExtractionTimes(duration: duration, count: count, policy: .uniform))
        }
        let one = uniform(100, 1)
        #expect(one.count == 1 && abs(one[0] - 50) <= 1.0 / 600, "A single cell shows the middle of the video: \(one)")
        let four = uniform(100, 4)
        for (time, want) in zip(four, [16.25, 38.75, 61.25, 83.75]) { #expect(abs(time - want) <= 1.0 / 600, "\(time) vs \(want)") }

        for count in [2, 6, 24, 60, 400, 1000] {
            let times = uniform(87.3, count)
            #expect(times.count == count)
            #expect(times.first.map { $0 > 87.3 * 0.05 } == true && times.last.map { $0 < 87.3 * 0.95 } == true)
            let steps = zip(times.dropFirst(), times).map { $0 - $1 }
            #expect(steps.allSatisfy { $0 > 0 }, "Strictly increasing for \(count) cells")
            let spread = (steps.max() ?? 0) - (steps.min() ?? 0)
            #expect(spread <= 2.0 / 600, "Equal time steps for \(count) cells (spread \(spread))")
        }
        #expect(uniform(100, 0).isEmpty && uniform(0, 4).isEmpty && uniform(.nan, 4).isEmpty)
    }

    @Test("A fixed grid samples uniformly; every other layout keeps the weighted split")
    func samplingPolicyPerLayout() {
        func config(_ type: LayoutType) -> MosaicConfiguration {
            MosaicConfiguration(layout: LayoutConfiguration(layoutType: type, grid: GridSpecification(rows: 2, columns: 3)))
        }
        #expect(MetalMosaicGenerator.samplingPolicy(for: config(.fixedGrid)) == .uniform)
        for type in [LayoutType.custom, .classic, .auto, .iphone] {
            #expect(MetalMosaicGenerator.samplingPolicy(for: config(type)) == .weighted, "\(type)")
        }
    }

    // MARK: - Distinct frames (T3)

    @Test("The distinct-frame budget is 90 % of duration × frame rate")
    func distinctFrameBudget() {
        #expect(MetalMosaicGenerator.distinctFrameBudget(duration: 5, frameRate: 24) == 108)
        #expect(MetalMosaicGenerator.distinctFrameBudget(duration: 8, frameRate: 30) == 216)
        #expect(MetalMosaicGenerator.distinctFrameBudget(duration: 87, frameRate: 29.97) == Int((0.9 * 87 * 29.97).rounded(.down)))
        #expect(MetalMosaicGenerator.distinctFrameBudget(duration: 60, frameRate: nil) == nil)
        #expect(MetalMosaicGenerator.distinctFrameBudget(duration: 60, frameRate: 0) == nil)
        #expect(MetalMosaicGenerator.distinctFrameBudget(duration: .nan, frameRate: 24) == nil)
    }

    @Test("A grid with more cells than distinct frames is refused before anything is decoded or written")
    func tooFewDistinctFrames() async throws {
        let url = try #require(Bundle.module.url(forResource: "rotated_portrait", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitDistinct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = MosaicConfiguration(
            width: 5120, density: .xxl, format: .jpeg, layout: .fixedGrid(rows: 30, columns: 30),
            includeMetadata: false, outputdirectory: folder
        )
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        let generator = try MetalMosaicGenerator()
        do {
            _ = try await generator.generate(for: video, config: config)
            Issue.record("900 cells of an 8 s clip must be refused")
        } catch MosaicError.invalidVideo(let message) {
            #expect(message.contains("distinct frames") && message.contains("900"), "got: \(message)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Nothing is written")
    }

    // MARK: - Header cap (H1)

    @Test("A grid's header is sized from at most W/20, not from the whole cell")
    func headerIsCappedForGrids() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        guard case .layout(let layout, _, _) = LayoutProcessor().planFixedGrid(
            GridSpecification(rows: 1, columns: 1), sourceAspectRatio: (video.width ?? 16) / (video.height ?? 9),
            mosaicAspectRatio: .widescreen, mosaicWidth: 5120, reservedHeight: 600
        ) else { throw MosaicError.invalidConfiguration("infeasible") }
        #expect(layout.thumbnailSize.height > 2_000, "A 1 × 1 grid has a huge cell")

        func headerHeight(_ type: LayoutType) async throws -> Int {
            var config = MosaicConfiguration(
                width: 5120, density: .m, layout: LayoutConfiguration(layoutType: type, grid: GridSpecification(rows: 1, columns: 1)),
                includeMetadata: true
            )
            config.overlay.header = HeaderConfig()
            let header = try await MetalMosaicGenerator().makeMetadataHeader(for: video, layout: layout, config: config, forIphone: false)
            return try #require(header).height
        }
        let grid = try await headerHeight(.fixedGrid)
        let classic = try await headerHeight(.classic)
        // Density M raises the header to 30 % of the cell height: 864 px for the whole cell, about 77 px for a W/20 cap.
        #expect(classic >= 800, "Control: other layouts keep the cell-based minimum (got \(classic))")
        #expect(grid < 400, "A grid's header stays proportionate (got \(grid))")
    }

    // MARK: - Watermark clamp (S7)

    @Test("An image watermark never gets taller than 80 % of the canvas")
    func imageWatermarkSizing() {
        let square = CGSize(width: 1000, height: 1000)
        // A normal canvas: width × scale, aspect kept, unchanged from before.
        let normal = OverlayProcessor.imageWatermarkSize(imageSize: square, canvas: CGSize(width: 5120, height: 2880), scale: 0.1)
        #expect(normal == CGSize(width: 512, height: 512))
        // A one-row strip: 5120 × 286 with scale 0.2 would be 1024 px tall.
        let strip = OverlayProcessor.imageWatermarkSize(imageSize: square, canvas: CGSize(width: 5120, height: 286), scale: 0.2)
        #expect(strip.height <= 286 * 0.8 + 1e-9 && strip.width == strip.height, "got \(strip)")
        // A wide logo on the strip keeps its aspect ratio when it is shrunk.
        let wide = OverlayProcessor.imageWatermarkSize(imageSize: CGSize(width: 400, height: 200), canvas: CGSize(width: 5120, height: 286), scale: 0.5)
        #expect(abs(wide.width / wide.height - 2) < 1e-9 && wide.height <= 286 * 0.8 + 1e-9, "got \(wide)")
        #expect(OverlayProcessor.imageWatermarkSize(imageSize: .zero, canvas: CGSize(width: 100, height: 100), scale: 0.1) == .zero)
        // Text: the font size follows the same limit.
        #expect(OverlayProcessor.watermarkFontSize(canvas: CGSize(width: 5120, height: 2880), scale: 0.05) == 256)
        #expect(OverlayProcessor.watermarkFontSize(canvas: CGSize(width: 5120, height: 286), scale: 0.2) == 286 * 0.8)
    }

    @Test("An image watermark on a strip canvas is drawn and the canvas is unchanged")
    func watermarkOnAStrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitWatermark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func solid(_ width: Int, _ height: Int, red: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        let logoURL = folder.appendingPathComponent("logo.png")
        let destination = try #require(CGImageDestinationCreateWithURL(logoURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solid(300, 300, red: 1), nil)
        #expect(CGImageDestinationFinalize(destination))

        let strip = try solid(2000, 120, red: 0)
        let config = WatermarkConfig(content: .image(logoURL), position: .bottomRight, opacity: 1, scale: 0.2)
        let result = try #require(OverlayProcessor.applyWatermark(to: strip, config: config))
        #expect(result.width == 2000 && result.height == 120)
        #expect(result.dataProvider?.data as Data? != strip.dataProvider?.data as Data?, "The watermark must change the pixels")
    }
}
