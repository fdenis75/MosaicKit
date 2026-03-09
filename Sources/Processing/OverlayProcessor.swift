import Foundation
import CoreGraphics
import ImageIO
import OSLog
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Post-mosaic overlay operations: Color DNA strip (2d) and watermark (2c).
///
/// All methods are static and platform-independent (CoreGraphics only).
/// They accept the fully assembled mosaic `CGImage` and return a new image
/// with the overlay composited on top.
public enum OverlayProcessor {

    private static let logger = Logger(subsystem: "com.mosaicKit", category: "overlay-processor")

    // MARK: - Color averaging (shared utility)

    /// Returns the average colour of a CGImage by scaling it down to a single pixel.
    /// Uses high-quality interpolation so the result is a true average, not a sampled pixel.
    public static func averageColor(of image: CGImage) -> CGColor {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = CGFloat(pixel[3]) / 255
        // Un-premultiply to recover true RGB values
        let r = alpha > 0 ? CGFloat(pixel[0]) / 255 / alpha : 0
        let g = alpha > 0 ? CGFloat(pixel[1]) / 255 / alpha : 0
        let b = alpha > 0 ? CGFloat(pixel[2]) / 255 / alpha : 0
        return CGColor(red: min(r, 1), green: min(g, 1), blue: min(b, 1), alpha: 1)
    }

    // MARK: - Color DNA strip (2d)

    /// Builds the Color DNA strip image (one coloured column per frame colour)
    /// and composites it above or below the mosaic.
    ///
    /// - Parameters:
    ///   - mosaic:       The fully assembled mosaic image.
    ///   - frameColors:  Dominant colour for each frame, in temporal order (index 0 = first frame).
    ///   - config:       DNA strip configuration.
    /// - Returns: A new image with the strip composited, or `nil` if the strip is disabled / cannot be rendered.
    public static func applyColorDNA(
        to mosaic: CGImage,
        frameColors: [CGColor],
        config: ColorDNAConfig
    ) -> CGImage? {
        guard config.show, !frameColors.isEmpty else { return nil }

        let mosaicW = mosaic.width
        let mosaicH = mosaic.height
        let stripH  = Int(config.height)
        let totalH  = mosaicH + stripH
        let colW    = CGFloat(mosaicW) / CGFloat(frameColors.count)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // --- Build the strip image ---
        guard let stripCtx = CGContext(
            data: nil,
            width: mosaicW, height: stripH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ ColorDNA: failed to create strip context")
            return nil
        }

        switch config.style {
        case .barcode:
            for (i, color) in frameColors.enumerated() {
                let x = CGFloat(i) * colW
                stripCtx.setFillColor(color)
                stripCtx.fill(CGRect(x: x, y: 0, width: colW, height: CGFloat(stripH)))
            }

        case .gradient:
            guard frameColors.count > 1 else {
                stripCtx.setFillColor(frameColors[0])
                stripCtx.fill(CGRect(x: 0, y: 0, width: mosaicW, height: stripH))
                break
            }
            for i in 0..<(frameColors.count - 1) {
                let segStart = CGFloat(i) * colW
                let segEnd   = CGFloat(i + 1) * colW
                let segRect  = CGRect(x: segStart, y: 0, width: segEnd - segStart, height: CGFloat(stripH))
                guard let gradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [frameColors[i], frameColors[i + 1]] as CFArray,
                    locations: [0.0, 1.0]
                ) else { continue }
                stripCtx.saveGState()
                stripCtx.clip(to: segRect)
                stripCtx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: segStart, y: 0),
                    end:   CGPoint(x: segEnd,   y: 0),
                    options: []
                )
                stripCtx.restoreGState()
            }
            // Fill the last column with the final colour to avoid a gap
            let lastX = CGFloat(frameColors.count - 1) * colW
            stripCtx.setFillColor(frameColors.last!)
            stripCtx.fill(CGRect(x: lastX, y: 0, width: CGFloat(mosaicW) - lastX, height: CGFloat(stripH)))
        }

        guard let stripImage = stripCtx.makeImage() else {
            logger.error("❌ ColorDNA: failed to create strip image")
            return nil
        }

        // --- Composite strip + mosaic ---
        guard let finalCtx = CGContext(
            data: nil,
            width: mosaicW, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ ColorDNA: failed to create composite context")
            return nil
        }

        // CGContext has bottom-left origin; draw accordingly.
        switch config.position {
        case .bottom:
            // Mosaic on top, strip at the bottom
            finalCtx.draw(mosaic,      in: CGRect(x: 0, y: stripH,  width: mosaicW, height: mosaicH))
            finalCtx.draw(stripImage,  in: CGRect(x: 0, y: 0,       width: mosaicW, height: stripH))
        case .top:
            // Strip on top, mosaic below
            finalCtx.draw(mosaic,      in: CGRect(x: 0, y: 0,       width: mosaicW, height: mosaicH))
            finalCtx.draw(stripImage,  in: CGRect(x: 0, y: mosaicH, width: mosaicW, height: stripH))
        }

        guard let result = finalCtx.makeImage() else {
            logger.error("❌ ColorDNA: failed to create final composite image")
            return nil
        }

        logger.debug("✅ ColorDNA strip applied — style: \(config.style.rawValue), height: \(stripH)px")
        return result
    }

    // MARK: - Watermark (2c)

    /// Composites a watermark (text or image) onto the assembled mosaic.
    ///
    /// - Parameters:
    ///   - mosaic:  The assembled mosaic image (after any DNA strip has been applied).
    ///   - config:  Watermark configuration.
    /// - Returns: A new image with the watermark drawn, or `nil` on failure.
    public static func applyWatermark(
        to mosaic: CGImage,
        config: WatermarkConfig
    ) -> CGImage? {
        let mosaicW = mosaic.width
        let mosaicH = mosaic.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: mosaicW, height: mosaicH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ Watermark: failed to create context")
            return nil
        }

        // Draw the base mosaic
        ctx.draw(mosaic, in: CGRect(x: 0, y: 0, width: mosaicW, height: mosaicH))

        ctx.setAlpha(CGFloat(config.opacity))

        switch config.content {
        case .text(let text):
            applyTextWatermark(text: text, in: ctx, mosaicW: mosaicW, mosaicH: mosaicH, config: config)
        case .image(let url):
            applyImageWatermark(url: url, in: ctx, mosaicW: mosaicW, mosaicH: mosaicH, config: config)
        }

        guard let result = ctx.makeImage() else {
            logger.error("❌ Watermark: failed to create result image")
            return nil
        }
        logger.debug("✅ Watermark applied — position: \(config.position.rawValue), opacity: \(config.opacity)")
        return result
    }

    // MARK: - Watermark helpers

    private static func applyTextWatermark(
        text: String,
        in ctx: CGContext,
        mosaicW: Int,
        mosaicH: Int,
        config: WatermarkConfig
    ) {
        // Font size = scale fraction of mosaic width, clamped to a readable range
        let fontSize = CGFloat(mosaicW) * CGFloat(config.scale)

        #if canImport(AppKit)
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        #elseif canImport(UIKit)
        let font = UIFont.boldSystemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        #endif

        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: attrs)

        let origin = watermarkOrigin(
            itemSize: textSize,
            mosaicW: mosaicW, mosaicH: mosaicH,
            position: config.position,
            margin: fontSize * 0.5
        )

        // Draw via CoreText so we don't need UIGraphics context
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform.identity
        ctx.translateBy(x: origin.x, y: origin.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func applyImageWatermark(
        url: URL,
        in ctx: CGContext,
        mosaicW: Int,
        mosaicH: Int,
        config: WatermarkConfig
    ) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let wmImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            logger.warning("⚠️ Watermark: could not load image from \(url.path)")
            return
        }

        let targetW = CGFloat(mosaicW) * CGFloat(config.scale)
        let aspect  = CGFloat(wmImage.height) / CGFloat(wmImage.width)
        let targetH = targetW * aspect
        let size    = CGSize(width: targetW, height: targetH)

        let origin = watermarkOrigin(
            itemSize: size,
            mosaicW: mosaicW, mosaicH: mosaicH,
            position: config.position,
            margin: targetW * 0.1
        )

        ctx.draw(wmImage, in: CGRect(origin: origin, size: size))
    }

    /// Computes the bottom-left origin for a watermark item (CGContext coordinate space).
    private static func watermarkOrigin(
        itemSize: CGSize,
        mosaicW: Int,
        mosaicH: Int,
        position: WatermarkPosition,
        margin: CGFloat
    ) -> CGPoint {
        let W = CGFloat(mosaicW)
        let H = CGFloat(mosaicH)
        let iW = itemSize.width
        let iH = itemSize.height

        switch position {
        case .topLeft:     return CGPoint(x: margin,          y: H - iH - margin)
        case .topRight:    return CGPoint(x: W - iW - margin, y: H - iH - margin)
        case .bottomLeft:  return CGPoint(x: margin,          y: margin)
        case .bottomRight: return CGPoint(x: W - iW - margin, y: margin)
        case .center:      return CGPoint(x: (W - iW) / 2,    y: (H - iH) / 2)
        }
    }
}
