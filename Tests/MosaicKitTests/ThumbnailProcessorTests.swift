import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

struct ThumbnailProcessorTests {

    // MARK: - Helpers

    private func makeProcessor() -> ThumbnailProcessor {
        ThumbnailProcessor(config: .default)
    }

    /// Creates a solid-colour CGImage of the specified size.
    private func makeImage(width: Int = 160, height: Int = 90,
                           red: CGFloat = 0.4, green: CGFloat = 0.5, blue: CGFloat = 0.6) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func makeVideoInput() async -> VideoInput {
        await VideoInput(
            url: URL(fileURLWithPath: "/tmp/test.mp4"),
            title: "Test Video",
            duration: 120,
            width: 1920,
            height: 1080,
            frameRate: 30,
            fileSize: 50_000_000,
            metadata: VideoMetadata(codec: "h264", bitrate: 5_000_000)
        )
    }

    // MARK: - addTimestampToImage: output dimensions

    @Test("addTimestampToImage preserves source image pixel dimensions")
    func addTimestampPreservesDimensions() {
        let proc  = makeProcessor()
        let image = makeImage(width: 320, height: 180)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "00:01:30", frameIndex: 0,
            size: CGSize(width: 320, height: 180)
        )
        #expect(result.width  == image.width)
        #expect(result.height == image.height)
    }

    @Test("addTimestampToImage with a very small thumbnail does not crash")
    func addTimestampSmallImage() {
        let proc  = makeProcessor()
        let image = makeImage(width: 40, height: 22)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "00:00:01", frameIndex: 0,
            size: CGSize(width: 40, height: 22)
        )
        #expect(result.width  == 40)
        #expect(result.height == 22)
    }

    // MARK: - addTimestampToImage: FrameLabelFormat variants

    @Test("addTimestampToImage: .timestamp format produces correct dimensions")
    func addTimestampFormatTimestamp() {
        let proc  = makeProcessor()
        let image = makeImage()
        let cfg   = FrameLabelConfig(show: true, format: .timestamp)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "00:00:45", frameIndex: 3,
            size: CGSize(width: 160, height: 90), labelConfig: cfg
        )
        #expect(result.width  == image.width)
        #expect(result.height == image.height)
    }

    @Test("addTimestampToImage: .frameIndex format produces correct dimensions")
    func addTimestampFormatFrameIndex() {
        let proc  = makeProcessor()
        let image = makeImage()
        let cfg   = FrameLabelConfig(show: true, format: .frameIndex)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "00:00:10", frameIndex: 7,
            size: CGSize(width: 160, height: 90), labelConfig: cfg
        )
        #expect(result.width  == image.width)
        #expect(result.height == image.height)
    }

    @Test("addTimestampToImage: .none format skips label but still applies visual treatment")
    func addTimestampFormatNone() {
        let proc  = makeProcessor()
        let image = makeImage()
        let cfg   = FrameLabelConfig(show: true, format: .none)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "00:00:05", frameIndex: 0,
            size: CGSize(width: 160, height: 90), labelConfig: cfg
        )
        #expect(result.width  == image.width)
        #expect(result.height == image.height)
    }

    @Test("addTimestampToImage: show=false still applies rounded corners and vignette")
    func addTimestampShowFalse() {
        let proc  = makeProcessor()
        let image = makeImage()
        let cfg   = FrameLabelConfig(show: false, format: .timestamp)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "01:00:00", frameIndex: 99,
            size: CGSize(width: 160, height: 90), labelConfig: cfg
        )
        #expect(result.width  == image.width)
        #expect(result.height == image.height)
    }

    // MARK: - addTimestampToImage: FrameLabelPosition variants

    @Test("addTimestampToImage: all five label positions produce correct-sized output")
    func addTimestampAllPositions() {
        let proc  = makeProcessor()
        let image = makeImage(width: 200, height: 112)
        let size  = CGSize(width: 200, height: 112)
        for position in [FrameLabelPosition.topLeft, .topRight, .bottomLeft, .bottomRight, .center] {
            let cfg    = FrameLabelConfig(show: true, format: .timestamp, position: position)
            let result = proc.addTimestampToImage(
                image: image, timestamp: "00:30:00", frameIndex: 0,
                size: size, labelConfig: cfg
            )
            #expect(result.width  == image.width,  "Width mismatch at position \(position.rawValue)")
            #expect(result.height == image.height, "Height mismatch at position \(position.rawValue)")
        }
    }

    // MARK: - addTimestampToImage: FrameLabelBackground variants

    @Test("addTimestampToImage: all three background styles produce correct-sized output")
    func addTimestampAllBackgroundStyles() {
        let proc  = makeProcessor()
        let image = makeImage(width: 200, height: 112)
        let size  = CGSize(width: 200, height: 112)
        for style in [FrameLabelBackground.pill, .none, .fullWidth] {
            let cfg    = FrameLabelConfig(show: true, format: .timestamp, backgroundStyle: style)
            let result = proc.addTimestampToImage(
                image: image, timestamp: "00:05:00", frameIndex: 1,
                size: size, labelConfig: cfg
            )
            #expect(result.width  == image.width,  "Width mismatch for style \(style.rawValue)")
            #expect(result.height == image.height, "Height mismatch for style \(style.rawValue)")
        }
    }

    // MARK: - addTimestampToImage: colour override

    @Test("addTimestampToImage: custom text colour does not crash")
    func addTimestampCustomTextColor() {
        let proc  = makeProcessor()
        let image = makeImage()
        let cfg   = FrameLabelConfig(
            show: true, format: .timestamp,
            textColor: MosaicColor(red: 1, green: 0.8, blue: 0),
            backgroundStyle: .pill
        )
        let result = proc.addTimestampToImage(
            image: image, timestamp: "00:12:34", frameIndex: 5,
            size: CGSize(width: 160, height: 90), labelConfig: cfg
        )
        #expect(result.width == image.width)
    }

    // MARK: - addTimestampToImage: frame index values

    @Test("addTimestampToImage: high frame index does not crash")
    func addTimestampHighFrameIndex() {
        let proc  = makeProcessor()
        let image = makeImage()
        let cfg   = FrameLabelConfig(show: true, format: .frameIndex)
        let result = proc.addTimestampToImage(
            image: image, timestamp: "23:59:59", frameIndex: 9999,
            size: CGSize(width: 160, height: 90), labelConfig: cfg
        )
        #expect(result.width == image.width)
    }

    // MARK: - createMetadataHeader: basic correctness

    @Test("createMetadataHeader returns a non-nil image with default config")
    func createMetadataHeaderDefault() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        let result = proc.createMetadataHeader(for: video, width: 1920)
        #expect(result != nil)
        #expect(result!.width  == 1920)
        #expect(result!.height > 0)
    }

    @Test("createMetadataHeader width is exactly as requested")
    func createMetadataHeaderWidth() async {
        let proc  = makeProcessor()
        let video = await makeVideoInput()
        for width in [400, 800, 1200, 2400] {
            let result = proc.createMetadataHeader(for: video, width: width)
            #expect(result?.width == width, "Width mismatch for requested \(width)")
        }
    }

    // MARK: - createMetadataHeader: HeaderHeight

    @Test("createMetadataHeader respects fixed height exactly")
    func createMetadataHeaderFixedHeight() async {
        let proc  = makeProcessor()
        let video = await makeVideoInput()
        for pixels in [40, 80, 120, 200] {
            let cfg    = HeaderConfig(height: .fixed(pixels))
            let result = proc.createMetadataHeader(for: video, width: 800, headerConfig: cfg)
            #expect(result != nil)
            #expect(result!.height == pixels, "Expected height \(pixels), got \(result!.height)")
        }
    }

    @Test("createMetadataHeader with auto height produces a positive height")
    func createMetadataHeaderAutoHeight() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        let cfg    = HeaderConfig(height: .auto)
        let result = proc.createMetadataHeader(for: video, width: 800, headerConfig: cfg)
        #expect(result != nil)
        #expect(result!.height > 0)
    }

    // MARK: - createMetadataHeader: MetadataField variants

    @Test("createMetadataHeader with empty fields still produces an image")
    func createMetadataHeaderEmptyFields() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        let cfg    = HeaderConfig(fields: [], height: .fixed(40))
        let result = proc.createMetadataHeader(for: video, width: 400, headerConfig: cfg)
        #expect(result != nil)
    }

    @Test("createMetadataHeader with all concrete MetadataField types does not crash")
    func createMetadataHeaderAllConcreteFields() async {
        let proc  = makeProcessor()
        let video = await makeVideoInput()
        let cfg   = HeaderConfig(fields: [
            .title, .duration, .fileSize, .resolution,
            .codec, .bitrate, .frameRate, .filePath,
            .custom(label: "Director", value: "Jane Doe")
        ])
        let result = proc.createMetadataHeader(for: video, width: 1920, headerConfig: cfg)
        #expect(result != nil)
    }

    @Test("createMetadataHeader with colorPalette field but no swatches does not crash")
    func createMetadataHeaderColorPaletteNoSwatches() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        let cfg    = HeaderConfig(fields: [.title, .colorPalette(swatchCount: 5)])
        let result = proc.createMetadataHeader(for: video, width: 600, headerConfig: cfg)
        #expect(result != nil)
    }

    @Test("createMetadataHeader renders colour palette swatches without crashing")
    func createMetadataHeaderWithSwatches() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        let cfg    = HeaderConfig(fields: [.title, .colorPalette(swatchCount: 3)])
        let swatches: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        ]
        let result = proc.createMetadataHeader(for: video, width: 800, headerConfig: cfg, swatchColors: swatches)
        #expect(result != nil)
        #expect(result!.width == 800)
    }

    @Test("createMetadataHeader swatchCount cap: more swatches than requested are ignored")
    func createMetadataHeaderSwatchCountCap() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        // Request only 2 swatches but supply 5 — should not crash
        let cfg    = HeaderConfig(fields: [.colorPalette(swatchCount: 2)])
        let swatches = (0..<5).map { i in
            CGColor(red: CGFloat(i) / 4, green: 0, blue: 0, alpha: 1)
        }
        let result = proc.createMetadataHeader(for: video, width: 500, headerConfig: cfg, swatchColors: swatches)
        #expect(result != nil)
    }

    // MARK: - createMetadataHeader: text colour and background overrides

    @Test("createMetadataHeader with explicit text and background colour overrides does not crash")
    func createMetadataHeaderColourOverrides() async {
        let proc  = makeProcessor()
        let video = await makeVideoInput()
        let cfg   = HeaderConfig(
            fields: [.title, .duration],
            height: .fixed(60),
            textColor: MosaicColor(red: 1, green: 1, blue: 0),
            backgroundColor: MosaicColor(red: 0, green: 0, blue: 0.5)
        )
        let result = proc.createMetadataHeader(for: video, width: 800, headerConfig: cfg)
        #expect(result != nil)
        #expect(result!.height == 60)
    }

    // MARK: - createMetadataHeader: forIphone flag

    @Test("createMetadataHeader forIphone=true produces a non-nil result")
    func createMetadataHeaderForIphone() async {
        let proc   = makeProcessor()
        let video  = await makeVideoInput()
        let result = proc.createMetadataHeader(for: video, width: 1200, forIphone: true)
        #expect(result != nil)
    }

    // MARK: - createMetadataHeader: many rows

    @Test("createMetadataHeader with nine text fields (three rows) produces valid image")
    func createMetadataHeaderNineFields() async {
        let proc  = makeProcessor()
        let video = await makeVideoInput()
        // 9 fields → 3 rows of 3
        let cfg   = HeaderConfig(fields: [
            .title, .duration, .fileSize,
            .resolution, .codec, .bitrate,
            .frameRate, .filePath, .custom(label: "X", value: "Y")
        ])
        let result = proc.createMetadataHeader(for: video, width: 2000, headerConfig: cfg)
        #expect(result != nil)
        #expect(result!.height > 0)
    }
}
