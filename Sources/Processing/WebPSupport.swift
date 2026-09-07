import Foundation
import CoreGraphics

/// Injected implementation of WebP encoding, provided by the separate
/// `MosaicKitWebP` product.
///
/// `MosaicKit`'s core target intentionally does **not** depend on `webp.swift`
/// (and transitively on the binary `libwebp-ios` xcframework): a binary
/// xcframework in a target's dependency graph breaks Xcode SwiftUI Preview's
/// JIT/dylib-patch execution ("JITError: Runtime linking failure") for any
/// client that links `MosaicKit` — including previews that never touch WebP
/// at all. Consumers that need `.webp` output link the additional
/// `MosaicKitWebP` product and call `MosaicKitWebP.register()` once at
/// startup; consumers that only need thumbnails/mosaics/UI stay free of the
/// binary dependency and keep fast JIT previews.
public protocol MosaicKitWebPEncoding: Sendable {
    /// Encode a single still image as WebP.
    func encodeStillWebP(_ image: CGImage, quality: Float) throws -> Data
    /// Encode an ordered sequence of frames as an animated WebP.
    func encodeAnimatedWebP(frames: [CGImage], frameDelay: Double) throws -> Data
}

/// Registration point for the injected WebP encoder. Set by
/// `MosaicKitWebP.register()`; `nil` until then.
public enum MosaicKitWebPSupport {
    public nonisolated(unsafe) static var encoder: (any MosaicKitWebPEncoding)?
}

public enum MosaicKitWebPError: Error, LocalizedError {
    case encoderNotRegistered

    public var errorDescription: String? {
        switch self {
        case .encoderNotRegistered:
            return "WebP output requires linking the MosaicKitWebP product and calling MosaicKitWebP.register() at startup."
        }
    }
}
