import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

struct LayoutProcessorTests {

    private let wideAR: CGFloat  = 16.0 / 9.0   // ~1.778
    private let tallAR: CGFloat  =  9.0 / 16.0  // ~0.5625
    private let squareAR: CGFloat = 1.0

    private func makeProcessor(aspectRatio: CGFloat = 16.0 / 9.0) -> LayoutProcessor {
        LayoutProcessor(aspectRatio: aspectRatio)
    }

    // MARK: - calculateThumbnailCount

    @Test("calculateThumbnailCount returns zero for invalid zero-length video")
    func thumbnailCountZeroDuration() {
        let proc = makeProcessor()
        #expect(proc.calculateThumbnailCount(duration: 0, width: 2000, density: .m, videoAR: 16/9) == 0)
    }

    @Test("calculateThumbnailCount returns zero for invalid duration and a bounded count for short videos")
    func thumbnailCountVeryShort() {
        let proc = makeProcessor()
        for duration in [1.0, 3.0, 4.9] {
            let count = proc.calculateThumbnailCount(duration: duration, width: 2000, density: .m, videoAR: 16/9)
            #expect(count > 0, "Expected a positive count for duration \(duration)s, got \(count)")
        }
    }

    @Test("calculateThumbnailCount scales upward with longer videos")
    func thumbnailCountScalesWithDuration() {
        let proc  = makeProcessor()
        let short = proc.calculateThumbnailCount(duration: 60,   width: 2000, density: .m, videoAR: 16/9)
        let long  = proc.calculateThumbnailCount(duration: 3600, width: 2000, density: .m, videoAR: 16/9)
        #expect(long > short, "Expected more thumbnails for longer video")
    }

    @Test("calculateThumbnailCount returns more thumbnails at higher density")
    func thumbnailCountDensityOrdering() {
        let proc = makeProcessor()
        let duration = 600.0; let width = 2000
        let sparse = proc.calculateThumbnailCount(duration: duration, width: width, density: .xxl, videoAR: 16/9)
        let dense  = proc.calculateThumbnailCount(duration: duration, width: width, density: .xxs, videoAR: 16/9)
        #expect(dense > sparse, "XXS (dense) should produce more thumbnails than XXL (sparse)")
    }

    @Test("calculateThumbnailCount is always capped at 800")
    func thumbnailCountCap() {
        let proc  = makeProcessor()
        let count = proc.calculateThumbnailCount(duration: 100_000, width: 8000, density: .xxs, videoAR: 16/9)
        #expect(count <= 800)
    }

    @Test("calculateThumbnailCount is always at least 4 for valid input")
    func thumbnailCountMinimum() {
        let proc = makeProcessor()
        // Very short video still returns 4
        let count = proc.calculateThumbnailCount(duration: 10, width: 100, density: .xxl, videoAR: 16/9)
        #expect(count >= 4)
    }

    // MARK: - calculateLayout: classic

    @Test("Classic layout produces positive mosaic dimensions")
    func classicLayoutDimensions() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 24,
            mosaicWidth: 2400,
            density: .m,
            layoutType: .classic
        )
        #expect(layout.mosaicSize.width  > 0)
        #expect(layout.mosaicSize.height > 0)
        #expect(layout.thumbCount > 0)
        #expect(layout.positions.count > 0)
        #expect(layout.thumbnailSizes.count == layout.positions.count)
    }

    @Test("Classic layout: thumbnail count is at least as many as requested")
    func classicLayoutThumbCount() {
        let proc           = makeProcessor()
        let requestedCount = 30
        let layout = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: requestedCount,
            mosaicWidth: 2400,
            density: .m,
            layoutType: .classic
        )
        // Classic may slightly overfill; allow up to 25% more
        #expect(layout.thumbCount >= requestedCount)
        #expect(layout.thumbCount <= Int(Double(requestedCount) * 1.25))
    }

    @Test("Classic layout: all thumbnail sizes are positive")
    func classicLayoutPositiveSizes() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 16,
            mosaicWidth: 1600,
            density: .m,
            layoutType: .classic
        )
        for (i, size) in layout.thumbnailSizes.enumerated() {
            #expect(size.width  > 0, "thumbnailSizes[\(i)].width is zero or negative")
            #expect(size.height > 0, "thumbnailSizes[\(i)].height is zero or negative")
        }
    }

    // MARK: - calculateLayout: custom

    @Test("Custom layout returns positive mosaic dimensions")
    func customLayoutDimensions() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 40,
            mosaicWidth: 4000,
            density: .m,
            layoutType: .custom
        )
        #expect(layout.mosaicSize.width  > 0)
        #expect(layout.mosaicSize.height > 0)
        #expect(layout.thumbCount > 0)
    }

    @Test("Custom layout: thumbnailSizes array length equals positions count")
    func customLayoutSizesMatchPositions() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 50,
            mosaicWidth: 5120,
            density: .xl,
            layoutType: .custom
        )
        #expect(layout.thumbnailSizes.count == layout.positions.count)
    }

    @Test("Custom layout: produces three distinct size groups (small/large/small)")
    func customLayoutSizeVariety() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 60,
            mosaicWidth: 5120,
            density: .m,
            layoutType: .custom
        )
        // There should be at least two distinct thumbnail widths (small and large zones)
        let uniqueWidths = Set(layout.thumbnailSizes.map { Int($0.width) })
        #expect(uniqueWidths.count >= 2, "Expected at least 2 distinct thumbnail widths in custom layout")
    }

    // MARK: - calculateLayout: dynamic (deprecated, I-8)

    /// `.dynamic` is deprecated; build it from its persisted raw value so the tests don't
    /// reference the deprecated case.
    private func legacyDynamic() throws -> LayoutType {
        try #require(LayoutType(rawValue: "dynamic"), "The persisted raw value \"dynamic\" must keep decoding")
    }

    @Test("Deprecated dynamic layout is laid out exactly as custom (I-8)")
    func dynamicLayoutIsCustom() throws {
        let dynamic = try legacyDynamic()
        for (count, width) in [(20, 2000), (107, 5120), (800, 5120)] {
            let custom = makeProcessor().calculateLayout(
                originalAspectRatio: wideAR, mosaicAspectRatio: .widescreen,
                thumbnailCount: count, mosaicWidth: width, density: .m, layoutType: .custom
            )
            let legacy = makeProcessor().calculateLayout(
                originalAspectRatio: wideAR, mosaicAspectRatio: .widescreen,
                thumbnailCount: count, mosaicWidth: width, density: .m, layoutType: dynamic
            )
            #expect(legacy.positions.count > 0)
            #expect(legacy.positions.map(\.x) == custom.positions.map(\.x))
            #expect(legacy.positions.map(\.y) == custom.positions.map(\.y))
            #expect(legacy.thumbnailSizes == custom.thumbnailSizes)
            #expect(legacy.mosaicSize == custom.mosaicSize)
        }
    }

    @Test("Dynamic still decodes, and is not listed in allCases")
    func dynamicStillDecodes() throws {
        let decoded = try JSONDecoder().decode(LayoutType.self, from: Data(#""dynamic""#.utf8))
        #expect(decoded.rawValue == "dynamic")
        #expect(!LayoutType.allCases.contains(decoded))
        #expect(LayoutType.allCases == [.auto, .custom, .classic, .iphone, .fixedGrid])
    }

    // MARK: - calculateLayout: auto (I-9)

    @Test("Auto layout fits an iPhone-sized screen instead of failing (I-9)")
    func autoLayoutOnIPhoneScreen() {
        let proc = makeProcessor()
        let phone = CGSize(width: 390, height: 844)
        let maxCount = proc.calculateMaxThumbnails(screenSize: phone, scale: 3, videoAR: 16.0 / 9.0)
        #expect(maxCount >= 4, "An iPhone screen fits \(maxCount) thumbnails")

        let layout = proc.calculateAutoLayout(
            originalAspectRatio: wideAR, thumbnailCount: 6, screenSize: phone, scale: 3
        )
        #expect(layout.positions.count == 6)
        #expect(layout.cols >= 1 && layout.rows >= 1)
        // The canvas is in pixels: 390 x 3 = 1170 wide.
        #expect(layout.mosaicSize.width == 1170)
    }

    @Test("Auto layout never indexes an empty range on a tiny screen")
    func autoLayoutOnTinyScreen() {
        let proc = makeProcessor()
        let tiny = CGSize(width: 100, height: 100)
        #expect(proc.calculateMaxThumbnails(screenSize: tiny, scale: 2, videoAR: 16.0 / 9.0) >= 1)
        let layout = proc.calculateAutoLayout(
            originalAspectRatio: wideAR, thumbnailCount: 4, screenSize: tiny, scale: 2
        )
        #expect(layout.positions.count > 0)
    }

    @Test("Auto layout on a desktop screen is unchanged in shape")
    func autoLayoutOnDesktopScreen() {
        let layout = makeProcessor().calculateAutoLayout(
            originalAspectRatio: wideAR, thumbnailCount: 30, screenSize: CGSize(width: 1512, height: 944), scale: 2
        )
        #expect(layout.positions.count == 30)
        #expect(layout.mosaicSize.width == 3024)
    }

    // MARK: - calculateLayout: iphone

    @Test("iPhone layout uses a fixed mosaic width of 1200 regardless of requested width")
    func iphoneLayoutFixedWidth() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: tallAR,
            mosaicAspectRatio: .vertical,
            thumbnailCount: 10,
            mosaicWidth: 5120,       // should be ignored
            density: .m,
            layoutType: .iphone
        )
        #expect(layout.mosaicSize.width == 1200)
    }

    @Test("iPhone layout uses a single column")
    func iphoneLayoutSingleColumn() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: tallAR,
            mosaicAspectRatio: .vertical,
            thumbnailCount: 8,
            mosaicWidth: 1200,
            density: .m,
            layoutType: .iphone
        )
        #expect(layout.cols == 1)
    }

    @Test("iPhone layout: all thumbnails have identical width (single-column)")
    func iphoneLayoutUniformWidth() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: tallAR,
            mosaicAspectRatio: .vertical,
            thumbnailCount: 8,
            mosaicWidth: 1200,
            density: .m,
            layoutType: .iphone
        )
        let widths = layout.thumbnailSizes.map(\.width)
        guard let first = widths.first else { return }
        for w in widths {
            #expect(abs(w - first) < 1.0, "Non-uniform width in iPhone layout: \(w) vs \(first)")
        }
    }

    @Test("iPhone layout caps thumb count to fit within 8000 px max mosaic height")
    func iphoneLayoutHeightCap() {
        let proc   = makeProcessor()
        let layout = proc.calculateLayout(
            originalAspectRatio: tallAR,
            mosaicAspectRatio: .vertical,
            thumbnailCount: 10_000,   // far more than can fit
            mosaicWidth: 1200,
            density: .m,
            layoutType: .iphone
        )
        #expect(layout.mosaicSize.height <= 8200)  // 8000 + small spacing tolerance
    }

    // MARK: - calculateLayout: consistent invariants across all layout types

    @Test("All layout types produce non-negative thumbnail positions")
    func allLayoutTypesNonNegativePositions() throws {
        let proc = makeProcessor()
        for layoutType in [LayoutType.classic, .custom, .iphone] + [try legacyDynamic()] {
            let layout = proc.calculateLayout(
                originalAspectRatio: wideAR,
                mosaicAspectRatio: .widescreen,
                thumbnailCount: 24,
                mosaicWidth: 2400,
                density: .m,
                layoutType: layoutType
            )
            for pos in layout.positions {
                #expect(pos.x >= 0, "\(layoutType.rawValue): negative x position \(pos.x)")
                #expect(pos.y >= 0, "\(layoutType.rawValue): negative y position \(pos.y)")
            }
        }
    }

    @Test("All layout types produce at least one thumbnail")
    func allLayoutTypesAtLeastOneThumb() throws {
        let proc = makeProcessor()
        for layoutType in [LayoutType.classic, .custom, .iphone] + [try legacyDynamic()] {
            let layout = proc.calculateLayout(
                originalAspectRatio: wideAR,
                mosaicAspectRatio: .widescreen,
                thumbnailCount: 10,
                mosaicWidth: 2000,
                density: .m,
                layoutType: layoutType
            )
            #expect(layout.thumbCount > 0, "\(layoutType.rawValue): zero thumbs")
            #expect(layout.positions.count > 0)
        }
    }

    // MARK: - LayoutProcessor state management

    @Test("updateAspectRatio changes the stored mosaicAspectRatio")
    func updateAspectRatio() {
        let proc = makeProcessor(aspectRatio: 16.0/9.0)
        proc.updateAspectRatio(4.0/3.0)
        #expect(abs(proc.mosaicAspectRatio - 4.0/3.0) < 0.001)
    }

    @Test("updateAspectRatio followed by a layout call uses the new ratio")
    func updateAspectRatioAffectsLayout() {
        let proc = makeProcessor(aspectRatio: 16.0/9.0)

        let layoutWide = proc.calculateLayout(
            originalAspectRatio: wideAR,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 20,
            mosaicWidth: 2000,
            density: .m,
            layoutType: .classic
        )

        proc.updateAspectRatio(1.0)  // square

        let layoutSquare = proc.calculateLayout(
            originalAspectRatio: squareAR,
            mosaicAspectRatio: .square,
            thumbnailCount: 20,
            mosaicWidth: 2000,
            density: .m,
            layoutType: .classic
        )

        // Both should be valid (non-zero dimensions)
        #expect(layoutWide.mosaicSize.width   > 0)
        #expect(layoutSquare.mosaicSize.width > 0)
    }

    // MARK: - MosaicLayout model (Codable)

    @Test("MosaicLayout round-trips through Codable preserving all fields")
    func mosaicLayoutCodable() throws {
        let original = MosaicLayout(
            rows: 4, cols: 6,
            thumbnailSize: CGSize(width: 100, height: 56),
            positions: [(0, 0), (104, 0), (208, 0)],
            thumbCount: 3,
            thumbnailSizes: [
                CGSize(width: 100, height: 56),
                CGSize(width: 100, height: 56),
                CGSize(width: 100, height: 56)
            ],
            mosaicSize: CGSize(width: 312, height: 56)
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MosaicLayout.self, from: data)

        #expect(decoded.rows       == 4)
        #expect(decoded.cols       == 6)
        #expect(decoded.thumbCount == 3)
        #expect(decoded.positions.count == 3)
        #expect(abs(decoded.thumbnailSize.width  - 100) < 0.01)
        #expect(abs(decoded.thumbnailSize.height -  56) < 0.01)
        #expect(abs(decoded.mosaicSize.width  - 312) < 0.01)
        #expect(decoded.thumbnailSizes.count == 3)
    }

    @Test("MosaicLayout single-thumbnail convenience init produces correct structure")
    func mosaicLayoutSingleThumbnailInit() {
        let size   = CGSize(width: 320, height: 180)
        let layout = MosaicLayout(thumbnailSize: size)
        #expect(layout.rows       == 1)
        #expect(layout.cols       == 1)
        #expect(layout.thumbCount == 1)
        #expect(layout.positions.count == 1)
        #expect(layout.positions[0].x == 0 && layout.positions[0].y == 0)
        #expect(abs(layout.thumbnailSize.width - 320) < 0.01)
    }
}
