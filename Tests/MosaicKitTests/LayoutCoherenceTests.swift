import CoreGraphics
import Testing
@testable import MosaicKit

/// I-39, I-40, I-41: more duration, density or width never gives fewer thumbnails, and the
/// settings are honored.
@Suite("Layout coherence")
struct LayoutCoherenceTests {
    static let layouts: [LayoutType] = [.classic, .custom, .auto]
    private static let sources: [CGFloat] = [16.0 / 9.0, 9.0 / 16.0, 4.0 / 3.0]
    private static let widths = [640, 1000, 2000, 3000, 5000, 10_000]
    private static let minutes: [Double] = [1, 5, 10, 15, 30, 60, 120]

    private static func layout(_ type: LayoutType, source: CGFloat, aspect: AspectRatio, width: Int,
                               density: DensityConfig, minutes: Double) -> (requested: Int, layout: MosaicLayout) {
        let processor = LayoutProcessor()
        let requested = processor.calculateThumbnailCount(
            duration: minutes * 60, width: width, density: density, layoutType: type, videoAR: source)
        return (requested, processor.calculateLayout(
            originalAspectRatio: source, mosaicAspectRatio: aspect, thumbnailCount: requested,
            mosaicWidth: width, density: density, layoutType: type))
    }

    @Test("Count never drops as duration, density or width grows", arguments: layouts)
    func monotonic(type: LayoutType) {
        var drops: [String] = []
        for source in Self.sources {
            for aspect in AspectRatio.allCases {
                func count(_ w: Int, _ d: DensityConfig, _ m: Double) -> Int {
                    Self.layout(type, source: source, aspect: aspect, width: w, density: d, minutes: m).layout.thumbCount
                }
                for width in Self.widths {
                    for density in DensityConfig.allCases {
                        let counts = Self.minutes.map { count(width, density, $0) }
                        if counts != counts.sorted() { drops.append("duration \(source) \(aspect) \(width) \(density.name) \(counts)") }
                    }
                    let counts = DensityConfig.allCases.map { count(width, $0, 15) }
                    if counts != counts.sorted() { drops.append("density \(source) \(aspect) \(width) \(counts)") }
                }
                for density in DensityConfig.allCases {
                    let counts = Self.widths.map { count($0, density, 15) }
                    if counts != counts.sorted() { drops.append("width \(source) \(aspect) \(density.name) \(counts)") }
                }
            }
        }
        #expect(drops.isEmpty, "\(drops.count) drops, first: \(drops.prefix(3))")
    }

    @Test("Width and cell floor are honored, and the requested count is met when it fits", arguments: layouts)
    func honorsSettings(type: LayoutType) {
        for source in Self.sources {
            for aspect in AspectRatio.allCases {
                for width in Self.widths {
                    for density in [DensityConfig.xxl, .m, .xxs] {
                        let (requested, layout) = Self.layout(type, source: source, aspect: aspect, width: width,
                                                              density: density, minutes: 15)
                        let name = "\(source) \(aspect) \(width) \(density.name)"
                        #expect(Int(layout.mosaicSize.width) == width, "\(name): \(layout.mosaicSize)")
                        #expect(layout.positions.count == layout.thumbCount && layout.thumbnailSizes.count == layout.thumbCount)
                        let narrowest = layout.thumbnailSizes.map(\.width).min() ?? 0
                        #expect(narrowest >= LayoutProcessor.minimumThumbnailWidth - 0.001, "\(name): \(narrowest)")
                        if narrowest > 2 * LayoutProcessor.minimumThumbnailWidth {
                            #expect(layout.thumbCount >= requested, "\(name): \(layout.thumbCount) < \(requested)")
                        }
                        for (position, size) in zip(layout.positions, layout.thumbnailSizes) {
                            #expect(position.x >= 0 && position.y >= 0)
                            #expect(CGFloat(position.x) + size.width <= layout.mosaicSize.width + 1, "\(name)")
                            #expect(CGFloat(position.y) + size.height <= layout.mosaicSize.height + 1, "\(name)")
                        }
                    }
                }
            }
        }
    }

    @Test("Classic and custom keep close to the requested mosaic aspect",
          arguments: [LayoutType.classic, .custom])
    func aspect(type: LayoutType) {
        for source in Self.sources {
            for aspect in AspectRatio.allCases {
                for width in [2000, 5000] {
                    let layout = Self.layout(type, source: source, aspect: aspect, width: width,
                                             density: .m, minutes: 30).layout
                    let ratio = (layout.mosaicSize.width / layout.mosaicSize.height) / aspect.ratio
                    #expect(ratio > 0.8 && ratio < 1.25, "\(source) \(aspect) \(width): \(ratio)")
                }
            }
        }
    }

    @Test("A large classic request on a narrow mosaic still follows the aspect (I-39)")
    func classicNarrow() {
        let processor = LayoutProcessor()
        let layout = processor.calculateLayout(
            originalAspectRatio: 16.0 / 9.0, mosaicAspectRatio: .vertical, thumbnailCount: 219,
            mosaicWidth: 1000, density: .xs, layoutType: .classic)
        #expect(layout.mosaicSize.height > layout.mosaicSize.width)
    }

    @Test("The auto layout takes the screen's shape and the configured width (I-41)")
    func autoScreenShape() {
        let layout = LayoutProcessor().calculateAutoLayout(
            originalAspectRatio: 16.0 / 9.0, thumbnailCount: 60, mosaicWidth: 3000,
            screenAspect: 390.0 / 844.0)
        #expect(layout.mosaicSize.width == 3000)
        #expect(layout.mosaicSize.height > layout.mosaicSize.width)
        #expect(layout.thumbCount >= 60)
    }
}
