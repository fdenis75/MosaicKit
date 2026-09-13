import Foundation

extension DensityConfig {
    /// Rejects invalid density before frame-count calculations.
    public func validate() throws {
        guard factor.isFinite, factor > 0, factor < Double(Int.max) / 16,
              extractsMultiplier.isFinite, extractsMultiplier > 0,
              extractsMultiplier < Double(Int.max) else {
            throw MosaicError.invalidConfiguration("Density factors must be finite, positive and representable as frame counts")
        }
    }
}

extension MosaicConfiguration {
    /// Validates geometry, numeric settings and optional encoder availability.
    /// Call again after changing mutable configuration properties.
    public func validate() throws {
        try density.validate()
        let height = Double(width) / Double(layout.aspectRatio.ratio)
        guard width > 0, height.isFinite, height > 0,
              Double(width) * height * 4 < Double(Int.max) else {
            throw MosaicError.invalidConfiguration("Mosaic dimensions must fit an addressable pixel buffer")
        }
        guard compressionQuality.isFinite, (0...1).contains(compressionQuality) else {
            throw MosaicError.invalidConfiguration("Compression quality must be finite and between zero and one")
        }
        guard gifFps.isFinite, gifFps > 0, gifFps <= 240 else {
            throw MosaicError.invalidConfiguration("Animation frame rate must be between zero (exclusive) and 240")
        }
        guard layout.spacing.isFinite, layout.spacing >= 0,
              layout.visual.borderWidth.isFinite, layout.visual.borderWidth >= 0 else {
            throw MosaicError.invalidConfiguration("Spacing and border width must be finite and nonnegative")
        }
        if let shadow = layout.visual.shadowSettings {
            guard shadow.radius.isFinite, shadow.radius >= 0,
                  shadow.opacity.isFinite, (0...1).contains(shadow.opacity),
                  shadow.offset.width.isFinite, shadow.offset.height.isFinite else {
                throw MosaicError.invalidConfiguration("Shadow geometry or opacity is invalid")
            }
        }
        if case .fixed(let height) = overlay.header.height, height <= 0 {
            throw MosaicError.invalidConfiguration("Fixed header height must be positive")
        }
        guard overlay.colorDNA.height.isFinite, overlay.colorDNA.height >= 0 else {
            throw MosaicError.invalidConfiguration("Color DNA height must be finite and nonnegative")
        }
        if let watermark = overlay.watermark {
            guard watermark.opacity.isFinite, (0...1).contains(watermark.opacity),
                  watermark.scale.isFinite, watermark.scale > 0 else {
                throw MosaicError.invalidConfiguration("Watermark scale or opacity is invalid")
            }
        }
        let colors = [backgroundColor, overlay.frameLabel.textColor,
                      overlay.header.textColor, overlay.header.backgroundColor].compactMap { $0 }
        for color in colors {
            guard [color.red, color.green, color.blue, color.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw MosaicError.invalidConfiguration("Color components must be finite and between zero and one")
            }
        }
        if (format == .webp && gifMode != .gifOnly) || (gifMode != .disabled && animatedFormat == .webp) {
            guard MosaicKitWebPSupport.encoder != nil else { throw MosaicKitWebPError.encoderNotRegistered }
        }
    }
}

extension PreviewConfiguration {
    /// Validates numeric settings and combinations supported by the selected exporter.
    public func validate() throws {
        do { try density.validate() } catch {
            throw PreviewError.invalidConfiguration("Density factors must be finite, positive and representable as frame counts")
        }
        guard targetDuration.isFinite, targetDuration > 0,
              targetDuration < Double(Int64.max) / 600 else {
            throw PreviewError.invalidConfiguration("Target duration must be finite, positive and representable as media time")
        }
        if let minimumExtractDuration,
           !minimumExtractDuration.isFinite || minimumExtractDuration <= 0 || minimumExtractDuration >= Double(Int64.max) / 600 {
            throw PreviewError.invalidConfiguration("Minimum extract duration must be finite and positive")
        }
        if let maximumPlaybackSpeed, !maximumPlaybackSpeed.isFinite || maximumPlaybackSpeed < 1 {
            throw PreviewError.invalidConfiguration("Maximum playback speed must be finite and at least one")
        }
        guard compressionQuality.isFinite, (0...1).contains(compressionQuality) else {
            throw PreviewError.invalidConfiguration("Compression quality must be finite and between zero and one")
        }
        if exportMode == .ffmpeg {
            #if !os(macOS)
            throw PreviewError.invalidConfiguration("FFmpeg process export is supported only on macOS")
            #else
            if showTimestampOverlay {
                throw PreviewError.invalidConfiguration("Timestamp overlays are not supported by the FFmpeg exporter")
            }
            if let options = ffmpegEncodingOptions, let crf = options.crf, !(0...51).contains(crf) {
                throw PreviewError.invalidConfiguration("FFmpeg CRF must be between zero and 51")
            }
            #endif
        }
        if exportMode == .native, exportPresetName == .AVAssetExportPresetPassthrough, showTimestampOverlay {
            throw PreviewError.invalidConfiguration("Passthrough export cannot render timestamp overlays")
        }
    }
}
