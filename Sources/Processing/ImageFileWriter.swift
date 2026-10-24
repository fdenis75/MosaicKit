import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Encodes one still image to a file. Shared by mosaic publication and thumbnail export; callers
/// write to an `OutputTransaction` staging URL and publish it themselves.
enum ImageFileWriter {
    /// Writes `image` to `url` as `format`. `compressionQuality` (0…1) applies to the lossy formats.
    /// `reportedURL` is the final location named in a `MosaicError.saveFailed`.
    static func write(
        _ image: CGImage,
        format: OutputFormat,
        compressionQuality: Double,
        to url: URL,
        reportedURL: URL
    ) throws {
        if format == .webp {
            guard let encoder = MosaicKitWebPSupport.encoder else {
                throw MosaicKitWebPError.encoderNotRegistered
            }
            let data = try encoder.encodeStillWebP(image, quality: Float(compressionQuality * 100))
            try data.write(to: url)
            return
        }

        let identifier: CFString
        switch format {
        case .jpeg:
            identifier = UTType.jpeg.identifier as CFString
        case .png:
            identifier = UTType.png.identifier as CFString
        case .heif:
            identifier = UTType.heic.identifier as CFString
        case .webp:
            identifier = UTType.webP.identifier as CFString
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, identifier, 1, nil) else {
            throw MosaicError.saveFailed(reportedURL, NSError(domain: "com.mosaicKit", code: -1))
        }

        var options: [String: Any] = [:]
        if format == .jpeg || format == .heif {
            options[kCGImageDestinationLossyCompressionQuality as String] = compressionQuality
        }
        if format == .heif {
            options[kCGImageDestinationEmbedThumbnail as String] = true
            options[kCGImagePropertyHasAlpha as String] = false
        }

        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw MosaicError.saveFailed(reportedURL, NSError(domain: "com.mosaicKit", code: -1))
        }
    }
}
