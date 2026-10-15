import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

/// `LayoutType.uneven` wired into the layout engine (plan step U-2; spec
/// `codebase-analysis-docs/specs/SPEC_UNEVEN_TILES_LAYOUT.md`, §6 and §11). The packer's own
/// geometry is covered by `UnevenTilePackerTests`.
struct UnevenLayoutTests {

    private func layout(
        count: Int = 107, width: Int = 5120, source: CGFloat = 16.0 / 9, aspect: AspectRatio = .widescreen,
        density: DensityConfig = .m, reserved: Int = 0, processor: LayoutProcessor = LayoutProcessor()
    ) -> MosaicLayout {
        processor.calculateLayout(
            originalAspectRatio: source, mosaicAspectRatio: aspect, thumbnailCount: count, mosaicWidth: width,
            density: density, layoutType: .uneven, reservedHeight: reserved
        )
    }

    // MARK: - Codable and identity

    @Test("The raw value is \"uneven\", it round-trips, and allCases lists it")
    func codable() throws {
        #expect(LayoutType.uneven.rawValue == "uneven")
        #expect(LayoutType.allCases.contains(.uneven))
        let config = MosaicConfiguration(width: 5120, density: .m, layout: LayoutConfiguration(layoutType: .uneven))
        let data = try JSONEncoder().encode(config)
        #expect(String(decoding: data, as: UTF8.self).contains("\"uneven\""))
        let decoded = try JSONDecoder().decode(MosaicConfiguration.self, from: data)
        #expect(decoded.layout.layoutType == .uneven)
        #expect(try JSONDecoder().decode(LayoutType.self, from: Data("\"uneven\"".utf8)) == .uneven)
    }

    @Test("The configuration hash ends in _uneven; other layouts keep theirs")
    func configurationHash() {
        #expect(MosaicConfiguration(width: 5120, density: .m, layout: LayoutConfiguration(layoutType: .uneven)).configurationHash
                == "5120_M_16-9_uneven")
        #expect(MosaicConfiguration(width: 5120, density: .m, layout: LayoutConfiguration(layoutType: .custom)).configurationHash
                == "5120_M_16-9_custom")
        #expect(MosaicConfiguration(width: 5120, density: .m, layout: LayoutConfiguration(layoutType: .classic)).configurationHash
                == "5120_M_16-9_classic")
    }

    // MARK: - Layout

    @Test("Density picks the largest tile: XXL/XL 2, L/M 3, S/XS 4, XXS 5")
    func densityTable() {
        let expected: [(DensityConfig, Int)] = [(.xxl, 2), (.xl, 2), (.l, 3), (.m, 3), (.s, 4), (.xs, 4), (.xxs, 5)]
        for (density, span) in expected {
            #expect(LayoutProcessor.unevenMaxSpan(for: density) == span, "\(density.name)")
        }
    }

    @Test("Until per-size extraction lands, no tile is larger than 2 × 2 unit tiles")
    func spanCap() {
        for density in [DensityConfig.m, .s, .xxs] {
            let result = layout(count: 400, density: density)
            let unit = result.thumbnailSize.width
            let widest = result.thumbnailSizes.map(\.width).max() ?? 0
            #expect(widest > unit * 1.5, "\(density.name): a larger tile exists")
            #expect(widest < unit * 2.5, "\(density.name): no tile above 2 × 2")
        }
    }

    @Test("The layout matches the packer, never overlaps and stays inside the canvas")
    func matchesPacker() {
        let result = layout()
        let plan = UnevenTilePacker.plan(sourceAspect: 16.0 / 9, targetAspect: 16.0 / 9, width: 5120, count: 107,
                                         maxSpan: LayoutProcessor.unevenSpanCap)
        let expected = UnevenTilePacker.layout(for: plan, width: 5120, sourceAspect: 16.0 / 9)
        #expect(result.thumbCount == expected.thumbCount)
        #expect(result.positions.map(\.x) == expected.positions.map(\.x))
        #expect(result.positions.map(\.y) == expected.positions.map(\.y))
        #expect(result.thumbnailSizes == expected.thumbnailSizes)
        #expect(result.mosaicSize == expected.mosaicSize)
        #expect(result.mosaicSize.width == 5120)
        let rects = zip(result.positions, result.thumbnailSizes).map {
            CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: $1.width, height: $1.height)
        }
        let canvas = CGRect(origin: .zero, size: result.mosaicSize)
        #expect(rects.allSatisfy { canvas.contains($0) })
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] where a.intersects(b) && !a.intersection(b).isEmpty {
                Issue.record("Overlap \(a) \(b)")
            }
        }
        #expect(abs(Double(result.thumbCount - 107)) / 107 <= 0.25)
    }

    @Test("Fewer than 12 frames or an extreme source aspect use the classic layout")
    func fallbacks() {
        let processor = LayoutProcessor()
        func classic(count: Int, source: CGFloat) -> MosaicLayout {
            processor.calculateLayout(originalAspectRatio: source, mosaicAspectRatio: .widescreen, thumbnailCount: count,
                                      mosaicWidth: 5120, density: .m, layoutType: .classic)
        }
        for (count, source) in [(4, 16.0 / 9), (11, 16.0 / 9), (107, 0.1), (107, 8.0)] as [(Int, CGFloat)] {
            let uneven = layout(count: count, source: source, processor: processor)
            let expected = classic(count: count, source: source)
            #expect(uneven.thumbCount == expected.thumbCount, "N=\(count) a=\(source)")
            #expect(uneven.mosaicSize == expected.mosaicSize, "N=\(count) a=\(source)")
            #expect(uneven.thumbnailSizes == expected.thumbnailSizes, "N=\(count) a=\(source)")
        }
    }

    @Test("The reserved height keeps the canvas below the texture limit, and is part of the cache key")
    func reservedHeight() {
        let processor = LayoutProcessor()
        let free = layout(count: 400, width: 10_000, aspect: .vertical, reserved: 0, processor: processor)
        let reserved = layout(count: 400, width: 10_000, aspect: .vertical, reserved: 2_000, processor: processor)
        #expect(free.mosaicSize.height <= 16_384)
        #expect(reserved.mosaicSize.height <= 16_384 - 2_000)
        #expect(reserved.mosaicSize.height < free.mosaicSize.height)
    }

    @Test("The generator reserves the header, a taller fixed header, and the ColorDNA strip")
    func generatorReserve() {
        var config = MosaicConfiguration(width: 5120, layout: LayoutConfiguration(layoutType: .uneven))
        config.includeMetadata = true
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        #expect(MetalMosaicGenerator.fixedGridReservedHeight(for: config) == 512 + 32)
        config.overlay.header.height = .fixed(900)
        #expect(MetalMosaicGenerator.fixedGridReservedHeight(for: config) == 900)
        config.overlay.header.height = .fixed(100)
        #expect(MetalMosaicGenerator.fixedGridReservedHeight(for: config) == 512 + 32)
    }

    @Test("forIphone still wins over .uneven")
    func iphoneWins() {
        let config = MosaicConfiguration(width: 5120, layout: LayoutConfiguration(layoutType: .uneven))
        #expect(MetalMosaicGenerator.effectiveLayoutType(config: config, forIphone: true) == .iphone)
        #expect(MetalMosaicGenerator.effectiveLayoutType(config: config, forIphone: false) == .uneven)
    }

    // MARK: - Integration (embedded media, kept small)

    @Test("test_video.mp4 at XXL comes out at the layout size, every tile composed")
    func endToEnd() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"), "Missing test fixture")
        let video = try await VideoInput(from: url)
        var config = MosaicConfiguration(
            width: 1200, density: .xxl, format: .jpeg, layout: LayoutConfiguration(layoutType: .uneven),
            includeMetadata: false, useAccurateTimestamps: false, compressionQuality: 0.5
        )
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)

        let processor = LayoutProcessor()
        let source = (video.width ?? 1) / (video.height ?? 1)
        let count = processor.calculateThumbnailCount(duration: video.duration ?? 0, width: 1200, density: .xxl,
                                                      layoutType: .uneven, videoAR: Double(source))
        let expected = processor.calculateLayout(originalAspectRatio: source, mosaicAspectRatio: .widescreen,
                                                 thumbnailCount: count, mosaicWidth: 1200, density: .xxl, layoutType: .uneven)
        #expect(count >= LayoutProcessor.unevenMinimumCount)
        #expect(expected.thumbnailSizes.contains { $0.width > expected.thumbnailSize.width * 1.5 })
        #expect(image.width == Int(expected.mosaicSize.width))
        #expect(image.height == Int(expected.mosaicSize.height))
    }
}
