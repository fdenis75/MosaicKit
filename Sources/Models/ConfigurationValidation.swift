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
        try validateFixedGrid()
    }

    /// Rejects a remote source (I-30) whose outputs would land next to it: without
    /// `outputdirectory` (or an absolute `outputDirectoryTemplate`), the output folder is the
    /// source URL's parent, which is not a local folder for an `https` link.
    public func validateOutputLocation(for video: VideoInput) throws {
        let root = outputdirectory ?? video.url.deletingLastPathComponent()
        guard generateOutputDirectory(rootDirectory: root, videoInput: video).isFileURL else {
            throw MosaicError.invalidConfiguration(
                "A remote video (\(video.url.scheme ?? "no scheme") URL) needs outputdirectory: outputs cannot be written next to it"
            )
        }
    }

    /// Checks a ``LayoutType/fixedGrid`` configuration. Only the configuration is known here; the
    /// checks that need the source video (its aspect ratio, frame count) run when the layout is
    /// planned.
    private func validateFixedGrid() throws {
        guard layout.layoutType == .fixedGrid else { return }
        guard let grid = layout.grid else {
            throw MosaicError.invalidConfiguration("The fixedGrid layout needs LayoutConfiguration.grid (rows and columns)")
        }
        let axisRange = 1...GridSpecification.maximumAxisCount
        guard axisRange.contains(grid.rows), axisRange.contains(grid.columns) else {
            throw MosaicError.invalidConfiguration(
                "A grid needs between 1 and \(GridSpecification.maximumAxisCount) rows and columns (got \(grid.rows) × \(grid.columns))"
            )
        }
        let cells = grid.rows * grid.columns
        guard cells <= GridSpecification.maximumCellCount else {
            throw MosaicError.invalidConfiguration(
                "A grid may have at most \(GridSpecification.maximumCellCount) cells (\(grid.rows) × \(grid.columns) is \(cells))"
            )
        }
        guard grid.aspectTolerance.isFinite, (0...0.25).contains(grid.aspectTolerance) else {
            throw MosaicError.invalidConfiguration("The grid aspect tolerance must be finite and between 0 and 0.25")
        }
        guard grid.minimumFill.isFinite, (0.1...1).contains(grid.minimumFill) else {
            throw MosaicError.invalidConfiguration("The grid minimum fill must be finite and between 0.1 and 1")
        }
        if gifMode != .disabled, cells < 4 {
            throw MosaicError.invalidConfiguration(
                "Animated exports need at least 4 cells (a \(grid.rows) × \(grid.columns) grid has \(cells))"
            )
        }
        // A frame is the cell minus the extra inset the renderer applies for spacing above 4 px.
        let gutter = 4
        // `spacing` is finite and nonnegative (checked above) but can be astronomically large; clamp it
        // before the Int conversion, which would trap. Such a value is rejected by the frame-size rule below.
        let inset = Int(min(max(layout.spacing.rounded() - Double(gutter), 0), 1_000_000))
        let frameWidth = (width - (grid.columns - 1) * gutter) / grid.columns - inset
        guard frameWidth >= GridSpecification.minimumFrameSide else {
            let usable = max(1, (width + gutter) / (GridSpecification.minimumFrameSide + gutter + inset))
            throw MosaicError.invalidConfiguration(
                "\(grid.columns) columns at width \(width) leave frames \(max(frameWidth, 0)) px wide; the minimum is \(GridSpecification.minimumFrameSide) px. Use at most \(usable) columns or a larger width"
            )
        }
        if grid.fit != .adaptCanvas {
            let canvasHeight = Int((Double(width) / Double(layout.aspectRatio.ratio)).rounded())
            let frameHeight = (canvasHeight - (grid.rows - 1) * gutter) / grid.rows - inset
            guard frameHeight >= GridSpecification.minimumFrameSide else {
                throw MosaicError.invalidConfiguration(
                    "\(grid.rows) rows in a \(layout.aspectRatio.rawValue) canvas of width \(width) leave frames \(max(frameHeight, 0)) px tall; the minimum is \(GridSpecification.minimumFrameSide) px. Use fewer rows, a larger width, or fit .adaptCanvas"
                )
            }
        }
    }
}

extension ThumbnailExtractionOptions {
    /// Rejects a count, size or quality that cannot be extracted, and `.webp` without a
    /// registered encoder.
    public func validate() throws {
        try validateFrameSelection()
        guard compressionQuality.isFinite, (0...1).contains(compressionQuality) else {
            throw MosaicError.invalidConfiguration("Compression quality must be finite and between zero and one")
        }
        if format == .webp, MosaicKitWebPSupport.encoder == nil {
            throw MosaicKitWebPError.encoderNotRegistered
        }
    }

    /// The checks in-memory extraction needs: it ignores `format` and `compressionQuality`.
    func validateFrameSelection() throws {
        guard (1...Self.maximumCount).contains(count) else {
            throw MosaicError.invalidConfiguration("Thumbnail count must be between 1 and \(Self.maximumCount) (got \(count))")
        }
        if let maximumSize {
            guard maximumSize.width.isFinite, maximumSize.height.isFinite,
                  maximumSize.width >= 1, maximumSize.height >= 1,
                  maximumSize.width <= 16_384, maximumSize.height <= 16_384 else {
                throw MosaicError.invalidConfiguration("Thumbnail maximum size must be between 1 and 16384 px on each side")
            }
        }
    }
}

extension PreviewConfiguration {
    /// Rejects a remote source (I-30) whose preview would land next to it: without
    /// `outputDirectory` (or an absolute `outputDirectoryTemplate`), the output folder is the
    /// source URL's parent, which is not a local folder for an `https` link.
    public func validateOutputLocation(for video: VideoInput) throws {
        guard generateOutputDirectory(for: video).isFileURL else {
            throw PreviewError.invalidConfiguration(
                "A remote video (\(video.url.scheme ?? "no scheme") URL) needs outputDirectory: the preview cannot be written next to it"
            )
        }
    }

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
