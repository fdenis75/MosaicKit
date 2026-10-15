import Foundation
import AVFoundation
import CoreGraphics
import Testing
@testable import MosaicKit

/// `MetadataField.colorPalette` used to be ignored because the generator never gave the header any
/// colors (implementation plan F-8d, knowledge base I-10).
struct ColorPaletteSwatchTests {

    private func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"),
                     "Missing test fixture test_video.mp4")
    }

    @Test("Palette sampling returns one color per requested swatch, capped at the maximum")
    func swatchColorsFromTheFixture() async throws {
        let url = try fixtureURL()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let processor = ThumbnailProcessor(config: .default)

        let colors = try await processor.paletteSwatchColors(url: url, duration: duration, count: 6)
        #expect(colors.count == 6)
        for color in colors {
            let components = try #require(color.components, "Swatch has no components")
            #expect(components.allSatisfy { $0 >= 0 && $0 <= 1 }, "Out-of-range swatch \(components)")
        }

        let capped = try await processor.paletteSwatchColors(url: url, duration: duration, count: 500)
        #expect(capped.count == ThumbnailProcessor.maximumPaletteSwatches)

        #expect(try await processor.paletteSwatchColors(url: url, duration: duration, count: 0).isEmpty)
        #expect(try await processor.paletteSwatchColors(url: url, duration: 0, count: 6).isEmpty)
    }

    @Test("A header with a .colorPalette field finds its swatch count; one without does not")
    func headerSwatchCount() {
        #expect(HeaderConfig(fields: [.title, .colorPalette(swatchCount: 7)]).paletteSwatchCount == 7)
        #expect(HeaderConfig(fields: [.title, .duration]).paletteSwatchCount == nil)
        #expect(HeaderConfig.default.paletteSwatchCount == nil)
    }

    @Test("createMetadataHeader draws the swatches it is given")
    func headerDrawsSwatches() throws {
        let processor = ThumbnailProcessor(config: .default)
        let video = VideoInput(canonicalID: UUID(), url: URL(fileURLWithPath: "/tmp/swatch.mp4"), title: "Swatch",
                               duration: 60, width: 1920, height: 1080)
        let header = HeaderConfig(fields: [.title, .colorPalette(swatchCount: 4)], height: .fixed(80))
        let colors = (0..<4).map { CGColor(red: Double($0) / 4, green: 0.2, blue: 1 - Double($0) / 4, alpha: 1) }

        let plain = try #require(processor.createMetadataHeader(for: video, width: 800, headerConfig: header))
        let painted = try #require(processor.createMetadataHeader(for: video, width: 800, headerConfig: header, swatchColors: colors))
        #expect(plain.width == painted.width && plain.height == painted.height)
        #expect(pixels(of: plain) != pixels(of: painted), "Swatches were not drawn")
    }

    @Test("The generator gives the header palette swatches when the header asks for them (I-10)")
    func generatorBuildsHeaderWithPalette() async throws {
        let url = try fixtureURL()
        let video = try await VideoInput(from: url)
        let layout = LayoutProcessor().calculateLayout(
            originalAspectRatio: (video.width ?? 16) / (video.height ?? 9), mosaicAspectRatio: .widescreen,
            thumbnailCount: 12, mosaicWidth: 1200, density: .m, layoutType: .classic
        )
        func config(fields: [MetadataField], includeMetadata: Bool = true) -> MosaicConfiguration {
            var config = MosaicConfiguration(
                width: 1200, density: .xxl, format: .png,
                layout: LayoutConfiguration(aspectRatio: .widescreen, layoutType: .classic),
                includeMetadata: includeMetadata, useAccurateTimestamps: false, compressionQuality: 0.5
            )
            config.overlay.header = HeaderConfig(fields: fields, height: .fixed(80))
            return config
        }
        let generator = try MetalMosaicGenerator()
        func header(_ fields: [MetadataField], includeMetadata: Bool = true) async throws -> CGImage? {
            try await generator.makeMetadataHeader(
                for: video, layout: layout,
                config: config(fields: fields, includeMetadata: includeMetadata), forIphone: false
            )
        }

        let plain = try #require(try await header([.title]))
        let plainAgain = try #require(try await header([.title]))
        let withPalette = try #require(try await header([.title, .colorPalette(swatchCount: 6)]))

        #expect(plain.width == withPalette.width && plain.height == withPalette.height)
        #expect(pixels(of: plain) == pixels(of: plainAgain), "Control: the header is deterministic without a palette")
        #expect(pixels(of: plain) != pixels(of: withPalette), "The palette field still renders nothing (I-10)")
        #expect(try await header([.title, .colorPalette(swatchCount: 6)], includeMetadata: false) == nil)
    }

    private func pixels(of image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
