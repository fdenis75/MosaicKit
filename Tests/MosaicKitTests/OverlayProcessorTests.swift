import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

struct OverlayProcessorTests {

    // MARK: - Test helpers

    /// Creates a solid-colour CGImage of the given size.
    private func makeImage(
        width: Int, height: Int,
        red: CGFloat = 0.5, green: CGFloat = 0.5, blue: CGFloat = 0.5
    ) -> CGImage {
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

    private func redColor()   -> CGColor { CGColor(red: 1, green: 0, blue: 0, alpha: 1) }
    private func blueColor()  -> CGColor { CGColor(red: 0, green: 0, blue: 1, alpha: 1) }
    private func greenColor() -> CGColor { CGColor(red: 0, green: 1, blue: 0, alpha: 1) }

    // MARK: - averageColor

    @Test("averageColor returns approximately red for a solid-red image")
    func averageColorRed() {
        let image = makeImage(width: 100, height: 100, red: 1, green: 0, blue: 0)
        let color = OverlayProcessor.averageColor(of: image)
        guard let comps = color.components, comps.count >= 3 else {
            #expect(Bool(false), "No color components"); return
        }
        #expect(comps[0] > 0.85, "Expected high red channel, got \(comps[0])")
        #expect(comps[1] < 0.15, "Expected low green channel")
        #expect(comps[2] < 0.15, "Expected low blue channel")
    }

    @Test("averageColor returns approximately blue for a solid-blue image")
    func averageColorBlue() {
        let image = makeImage(width: 80, height: 80, red: 0, green: 0, blue: 1)
        let color = OverlayProcessor.averageColor(of: image)
        guard let comps = color.components, comps.count >= 3 else {
            #expect(Bool(false), "No color components"); return
        }
        #expect(comps[0] < 0.15)
        #expect(comps[2] > 0.85)
    }

    @Test("averageColor returns mid-gray for a 50% gray image")
    func averageColorGray() {
        let image = makeImage(width: 64, height: 64, red: 0.5, green: 0.5, blue: 0.5)
        let color = OverlayProcessor.averageColor(of: image)
        guard let comps = color.components, comps.count >= 3 else {
            #expect(Bool(false), "No color components"); return
        }
        for ch in 0..<3 {
            #expect(comps[ch] > 0.35 && comps[ch] < 0.65, "Channel \(ch) out of range: \(comps[ch])")
        }
    }

    @Test("averageColor returns a color with alpha == 1")
    func averageColorAlpha() {
        let image = makeImage(width: 10, height: 10)
        let color = OverlayProcessor.averageColor(of: image)
        guard let comps = color.components, comps.count == 4 else { return }
        #expect(comps[3] == 1.0)
    }

    // MARK: - applyColorDNA: guard conditions

    @Test("applyColorDNA returns nil when show is false")
    func applyColorDNADisabled() {
        let mosaic = makeImage(width: 200, height: 100)
        let config = ColorDNAConfig(show: false, height: 20, position: .bottom, style: .barcode)
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: [redColor()], config: config)
        #expect(result == nil)
    }

    @Test("applyColorDNA returns nil when frameColors is empty")
    func applyColorDNAEmptyColors() {
        let mosaic = makeImage(width: 200, height: 100)
        let config = ColorDNAConfig(show: true, height: 20, position: .bottom, style: .barcode)
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: [], config: config)
        #expect(result == nil)
    }

    // MARK: - applyColorDNA: dimensions

    @Test("applyColorDNA barcode bottom: result height = mosaicH + stripH")
    func applyColorDNABarcodeDimensionsBottom() {
        let mosaicW = 400; let mosaicH = 200; let stripH = 30
        let mosaic = makeImage(width: mosaicW, height: mosaicH)
        let colors = (0..<8).map { _ in redColor() }
        let config = ColorDNAConfig(show: true, height: CGFloat(stripH), position: .bottom, style: .barcode)
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: colors, config: config)
        #expect(result != nil)
        #expect(result!.width  == mosaicW)
        #expect(result!.height == mosaicH + stripH)
    }

    @Test("applyColorDNA gradient top: result height = mosaicH + stripH")
    func applyColorDNAGradientDimensionsTop() {
        let mosaicH = 150; let stripH = 24
        let mosaic = makeImage(width: 300, height: mosaicH)
        let config = ColorDNAConfig(show: true, height: CGFloat(stripH), position: .top, style: .gradient)
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: [redColor(), blueColor()], config: config)
        #expect(result != nil)
        #expect(result!.width  == 300)
        #expect(result!.height == mosaicH + stripH)
    }

    // MARK: - applyColorDNA: style and position coverage

    @Test("applyColorDNA: all style × position combinations produce non-nil results")
    func applyColorDNAAllCombinations() {
        let mosaic = makeImage(width: 200, height: 100)
        let colors = [redColor(), greenColor(), blueColor()]
        for style    in [ColorDNAStyle.barcode, .gradient] {
            for position in [ColorDNAPosition.top, .bottom] {
                let config = ColorDNAConfig(show: true, height: 20, position: position, style: style)
                let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: colors, config: config)
                #expect(result != nil, "nil for style=\(style.rawValue) position=\(position.rawValue)")
            }
        }
    }

    @Test("applyColorDNA gradient with a single color does not crash")
    func applyColorDNASingleColorGradient() {
        let mosaic = makeImage(width: 100, height: 50)
        let config = ColorDNAConfig(show: true, height: 16, position: .bottom, style: .gradient)
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: [greenColor()], config: config)
        #expect(result != nil)
        #expect(result!.height == 50 + 16)
    }

    @Test("applyColorDNA with many frame colors does not crash")
    func applyColorDNAManyColors() {
        let mosaic = makeImage(width: 800, height: 200)
        let colors = (0..<100).map { i -> CGColor in
            CGColor(red: CGFloat(i % 3 == 0 ? 1 : 0),
                    green: CGFloat(i % 3 == 1 ? 1 : 0),
                    blue:  CGFloat(i % 3 == 2 ? 1 : 0),
                    alpha: 1)
        }
        let config = ColorDNAConfig(show: true, height: 24, position: .bottom, style: .barcode)
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: colors, config: config)
        #expect(result != nil)
        #expect(result!.width == 800)
    }

    // MARK: - applyColorDNA: minimum strip height clamp

    @Test("applyColorDNA respects minimum strip height of 8 px from config clamp")
    func applyColorDNAMinStripHeight() {
        let mosaicH = 100
        let mosaic = makeImage(width: 200, height: mosaicH)
        // ColorDNAConfig clamps height to 8 minimum
        let config = ColorDNAConfig(show: true, height: 4, position: .bottom, style: .barcode)
        #expect(config.height == 8)  // clamp happens in init
        let result = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: [redColor()], config: config)
        #expect(result != nil)
        #expect(result!.height == mosaicH + 8)
    }

    // MARK: - applyWatermark: dimensions

    @Test("applyWatermark text: output dimensions match the input mosaic exactly")
    func applyWatermarkTextDimensions() {
        let mosaic = makeImage(width: 500, height: 300)
        let config = WatermarkConfig(content: .text("© Test"), position: .bottomRight, opacity: 0.5, scale: 0.1)
        let result = OverlayProcessor.applyWatermark(to: mosaic, config: config)
        #expect(result != nil)
        #expect(result!.width  == 500)
        #expect(result!.height == 300)
    }

    @Test("applyWatermark text: all five positions produce non-nil results with correct size")
    func applyWatermarkAllPositions() {
        let mosaic = makeImage(width: 400, height: 200)
        for position in [WatermarkPosition.topLeft, .topRight, .bottomLeft, .bottomRight, .center] {
            let config = WatermarkConfig(content: .text("WM"), position: position, opacity: 0.4, scale: 0.08)
            let result = OverlayProcessor.applyWatermark(to: mosaic, config: config)
            #expect(result != nil, "Watermark failed for position \(position.rawValue)")
            #expect(result?.width  == 400)
            #expect(result?.height == 200)
        }
    }

    @Test("applyWatermark with missing image URL returns a non-nil result (graceful degradation)")
    func applyWatermarkMissingImage() {
        let mosaic = makeImage(width: 200, height: 100)
        let config = WatermarkConfig(
            content: .image(URL(fileURLWithPath: "/nonexistent/path/logo.png")),
            position: .center, opacity: 0.5, scale: 0.1
        )
        // Should not crash; the mosaic is drawn into the context; the watermark image is skipped
        let result = OverlayProcessor.applyWatermark(to: mosaic, config: config)
        #expect(result != nil)
        #expect(result!.width  == 200)
        #expect(result!.height == 100)
    }

    // MARK: - applyWatermark: opacity extremes

    @Test("applyWatermark at zero opacity still returns a valid image")
    func applyWatermarkZeroOpacity() {
        let mosaic = makeImage(width: 100, height: 100)
        let config = WatermarkConfig(content: .text("Invisible"), opacity: 0.0, scale: 0.1)
        let result = OverlayProcessor.applyWatermark(to: mosaic, config: config)
        #expect(result != nil)
    }

    @Test("applyWatermark at full opacity still returns a valid image")
    func applyWatermarkFullOpacity() {
        let mosaic = makeImage(width: 100, height: 100)
        let config = WatermarkConfig(content: .text("Solid"), opacity: 1.0, scale: 0.1)
        let result = OverlayProcessor.applyWatermark(to: mosaic, config: config)
        #expect(result != nil)
    }

    // MARK: - applyWatermark: various scale values

    @Test("applyWatermark at large scale (0.5) does not crash")
    func applyWatermarkLargeScale() {
        let mosaic = makeImage(width: 400, height: 200)
        let config = WatermarkConfig(content: .text("BIG"), position: .center, opacity: 0.3, scale: 0.5)
        let result = OverlayProcessor.applyWatermark(to: mosaic, config: config)
        #expect(result != nil)
        #expect(result!.width == 400)
    }

    // MARK: - applyWatermark combined with applyColorDNA

    @Test("Applying ColorDNA then Watermark in sequence produces a valid image")
    func colorDNAThenWatermark() {
        let mosaic = makeImage(width: 400, height: 200)
        let colors = [redColor(), blueColor(), greenColor()]
        let dnaConfig = ColorDNAConfig(show: true, height: 20, position: .bottom, style: .barcode)
        let withDNA = OverlayProcessor.applyColorDNA(to: mosaic, frameColors: colors, config: dnaConfig)
        #expect(withDNA != nil)

        let wmConfig = WatermarkConfig(content: .text("© 2025"), position: .bottomRight, opacity: 0.4, scale: 0.08)
        let result = OverlayProcessor.applyWatermark(to: withDNA!, config: wmConfig)
        #expect(result != nil)
        // Height should be mosaic + DNA strip
        #expect(result!.height == 200 + 20)
        #expect(result!.width  == 400)
    }
}
