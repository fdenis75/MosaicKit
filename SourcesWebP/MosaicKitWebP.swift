import Foundation
import CoreGraphics
import MosaicKit
import webp
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Default `MosaicKitWebPEncoding` backed by `webp.swift` / `libwebp-ios`.
///
/// This target is the only place in the dependency graph that touches the
/// binary `libwebp-ios` xcframework, so only clients that actually need
/// `.webp` output should link `MosaicKitWebP` — everything else (including
/// UI-only consumers previewed in Xcode) links plain `MosaicKit` and stays
/// free of the binary dependency. See `MosaicKit/Processing/WebPSupport.swift`
/// for the rationale.
public struct DefaultMosaicKitWebPEncoder: MosaicKitWebPEncoding {
    public init() {}

    public func encodeStillWebP(_ image: CGImage, quality: Float) throws -> Data {
        let config = WebpEncoderConfig.preset(.picture, quality: quality)
        return try WebPEncoder().encode(RGBA: image, config: config)
    }

    public func encodeAnimatedWebP(frames: [CGImage], frameDelay: Double) throws -> Data {
        guard let first = frames.first else { return Data() }
        let encoder = WebPAnimatedEncoder()
        let config = WebpEncoderConfig.preset(.picture, quality: 80)
        try encoder.create(config: config, width: first.width, height: first.height)
        let durationMs = Int(frameDelay * 1000)
        for frame in frames {
            try Task.checkCancellation()
            try encoder.addImage(image: makePlatformImage(from: frame), duration: durationMs)
        }
        return try encoder.encode(loopCount: 0)
    }

    private func makePlatformImage(from cgImage: CGImage) -> WebPPlatformImage {
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

public enum MosaicKitWebP {
    /// Enables `.webp` output for `MetalMosaicGenerator`/`AnimatedGifGenerator`.
    ///
    /// Call once at app/CLI startup — not from a SwiftUI Preview context, since
    /// linking this product back into a previewed target reintroduces the
    /// binary-xcframework JIT problem this split exists to avoid.
    public static func register() {
        MosaicKitWebPSupport.encoder = DefaultMosaicKitWebPEncoder()
    }
}
