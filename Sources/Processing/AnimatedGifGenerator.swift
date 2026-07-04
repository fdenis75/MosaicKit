import Foundation
import CoreGraphics
import ImageIO
import OSLog
import webp
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Creates animated image files from a sequence of `CGImage` frames using Core Graphics / ImageIO.
///
/// Supports GIF, animated HEIC (HEICS), and animated WebP via `CGImageDestination`.
public struct AnimatedGifGenerator: Sendable {

    private static let logger = Logger(subsystem: "com.mosaicKit", category: "gif-generator")

    /// Saves an animated image to disk from an ordered array of frames.
    /// - Parameters:
    ///   - frames: Ordered sequence of frames (no timestamp overlay).
    ///   - url: Destination file URL; the parent directory must already exist.
    ///   - format: Container format (`gif`, `heic`, or `webp`). Defaults to `.gif`.
    ///   - frameDelay: Duration each frame is displayed, in seconds.
    public static func save(
        frames: [CGImage],
        to url: URL,
        format: AnimatedFormat = .gif,
        frameDelay: Double = 1.0 / 10.0
    ) throws {
        guard !frames.isEmpty else {
            logger.warning("⚠️ Animated image save skipped — no frames provided")
            return
        }

        if format == .webp {
            try saveWebP(frames: frames, to: url, frameDelay: frameDelay)
            return
        }

        guard format.isWritable else {
            throw MosaicError.saveFailed(url, NSError(
                domain: "com.mosaicKit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(format.rawValue.uppercased()) animated writing is not supported by CGImageDestination on this platform"]
            ))
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.uti as CFString,
            frames.count,
            nil
        ) else {
            throw MosaicError.saveFailed(url, NSError(
                domain: "com.mosaicKit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create \(format.rawValue.uppercased()) image destination"]
            ))
        }

        CGImageDestinationSetProperties(destination, containerProperties(for: format) as CFDictionary)

        let frameProps = frameProperties(for: format, delay: frameDelay)
        for frame in frames {
            // Respects cancellation of the surrounding task when called from an
            // async context; a no-op when there is no task.
            try Task.checkCancellation()
            CGImageDestinationAddImage(destination, frame, frameProps as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw MosaicError.saveFailed(url, NSError(
                domain: "com.mosaicKit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationFinalize failed for \(format.rawValue.uppercased())"]
            ))
        }

        logger.debug("✅ \(format.rawValue.uppercased()) saved — \(frames.count) frames at \(String(format: "%.3f", frameDelay))s/frame → \(url.lastPathComponent)")
    }

    // MARK: - Private helpers

    private static func saveWebP(frames: [CGImage], to url: URL, frameDelay: Double) throws {
        guard let first = frames.first else { return }
        let encoder = WebPAnimatedEncoder()
        let config = WebpEncoderConfig.preset(.picture, quality: 80)
        try encoder.create(config: config, width: first.width, height: first.height)
        let durationMs = Int(frameDelay * 1000)
        for frame in frames {
            try Task.checkCancellation()
            try encoder.addImage(image: makePlatformImage(from: frame), duration: durationMs)
        }
        let data = try encoder.encode(loopCount: 0)
        try data.write(to: url)
        logger.debug("✅ WEBP saved — \(frames.count) frames at \(String(format: "%.3f", frameDelay))s/frame → \(url.lastPathComponent)")
    }

    private static func makePlatformImage(from cgImage: CGImage) -> WebPPlatformImage {
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    private static func containerProperties(for format: AnimatedFormat) -> [String: Any] {
        switch format {
        case .gif:
            return [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFLoopCount as String: 0  // 0 = loop forever
                ]
            ]
        case .heic:
            return [
                kCGImagePropertyHEICSDictionary as String: [
                    kCGImagePropertyHEICSLoopCount as String: 0
                ]
            ]
        case .webp:
            return [
                kCGImagePropertyWebPDictionary as String: [
                    kCGImagePropertyWebPLoopCount as String: 0
                ]
            ]
        }
    }

    private static func frameProperties(for format: AnimatedFormat, delay: Double) -> [String: Any] {
        switch format {
        case .gif:
            return [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay
                ]
            ]
        case .heic:
            return [
                kCGImagePropertyHEICSDictionary as String: [
                    kCGImagePropertyHEICSDelayTime as String: delay,
                    kCGImagePropertyHEICSUnclampedDelayTime as String: delay
                ]
            ]
        case .webp:
            return [
                kCGImagePropertyWebPDictionary as String: [
                    kCGImagePropertyWebPDelayTime as String: delay,
                    kCGImagePropertyWebPUnclampedDelayTime as String: delay
                ]
            ]
        }
    }
}
