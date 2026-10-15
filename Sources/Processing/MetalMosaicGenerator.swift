import Foundation
import AVFoundation
import CoreImage
import OSLog
import Metal
import VideoToolbox
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Thread-safe accumulator for per-frame average colours used by the Color DNA strip.
private actor FrameColorCollector {
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "frame-color-collector")
    private var colors: [Int: CGColor] = [:]

    func store(_ color: CGColor, at index: Int) {
        signposter.emitEvent("store")
        let intervalState = signposter.beginInterval("store")
        defer { signposter.endInterval("store", intervalState) }
        colors[index] = color
    }

    /// Returns colours sorted by frame index (temporal order), up to `count` entries.
    func orderedColors(count: Int) -> [CGColor] {
        signposter.emitEvent("orderedColors")
        let intervalState = signposter.beginInterval("orderedColors")
        defer { signposter.endInterval("orderedColors", intervalState) }
        return (0..<count).compactMap { colors[$0] }
    }
}

/// A Metal-accelerated implementation of the MosaicGeneratorProtocol
public actor MetalMosaicGenerator: MosaicGeneratorProtocol {
    // MARK: - Properties
    
    private static let staticSignposter = OSSignposter(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")
    private let logger = Logger(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")
    private let metalProcessor: MetalImageProcessor
    private let layoutProcessor: LayoutProcessor
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "metal-mosaic-generator")

    private var generationTasks: [UUID: [UUID: Task<URL, Error>]] = [:]
    private var imageGenerationTasks: [UUID: [UUID: Task<CGImage, Error>]] = [:]
    private var progressHandlerRevisions: [UUID: UUID] = [:]
    private var progressHandlers: [UUID: @Sendable (MosaicGenerationProgress) -> Void] = [:]
    
    // Performance metrics
    private var lastGenerationTime: CFAbsoluteTime = 0
    private var totalGenerationTime: CFAbsoluteTime = 0
    private var generationCount: Int = 0
    private let thumbnailProcessor: ThumbnailProcessor
    
    // MARK: - Initialization
    
    /// Initialize a new Metal-accelerated mosaic generator
    /// - Parameter layoutProcessor: The layout processor to use
    public init(layoutProcessor: LayoutProcessor = LayoutProcessor()) throws {
        Self.staticSignposter.emitEvent("init")
        let intervalState = Self.staticSignposter.beginInterval("init")
        defer { Self.staticSignposter.endInterval("init", intervalState) }
        self.layoutProcessor = layoutProcessor
        self.thumbnailProcessor = ThumbnailProcessor(config: .default)
        self.metalProcessor = try MetalImageProcessor()
    }
    
    @available(*, deprecated, message: "Ignores most of the configuration it is given. Removed in MosaicKit 2.0. Call generate(for:config:forIphone:) once per configuration.")
    public func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL] {
        signposter.emitEvent("generateallcombinations")
        let intervalState = signposter.beginInterval("generateallcombinations")
        defer { signposter.endInterval("generateallcombinations", intervalState) }
        let sizes = [2000,5000,10000]
        let densities: [DensityConfig] = DensityConfig.allCases
        
        var mosaics: [URL] = []
        
        for size in sizes {
            for density in densities {
                try Task.checkCancellation()
                let config = MosaicConfiguration(width: size, density: density, format: .heif, layout: .default, includeMetadata: true, useAccurateTimestamps: true, compressionQuality: 0.4)
                let mosaic = try await generate(for: video, config: config)
                mosaics.append(mosaic)
            }
        }
        return mosaics
    }
    
    // MARK: - MosaicGenerating
    

    /// Generate a mosaic for a video using Metal acceleration
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    /// - Returns: The URL of the generated mosaic image
    public func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false) async throws -> URL {
        signposter.emitEvent("generate")
        let intervalState = signposter.beginInterval("generate")
        defer { signposter.endInterval("generate", intervalState) }
        try config.validate()
        let videoID = video.id

        try Task.checkCancellation()
        let attemptID = UUID()
        layoutProcessor.mosaicAspectRatio = config.layout.aspectRatio.ratio

        // Resolved once and reused for both the existence check below and the
        // actual save, so a `{time}` token in outputDirectoryTemplate can't
        // resolve to a different directory between the two (generation can
        // take many seconds).
        let referenceDate = Date()

        let attemptProgressHandler = progressHandlers[videoID]
        let handlerRevision = progressHandlerRevisions[videoID]
        let task = Task<URL, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            defer { trackPerformance(startTime: startTime) }

            try Task.checkCancellation()

            // Early-exit: if the output already exists and `overwrite` is false,
            // skip generation entirely and return the existing URL.
            if !config.overwrite {
                if config.gifMode == .gifOnly {
                    let animURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)
                    if FileManager.default.fileExists(atPath: animURL.path) {
                        logger.debug("⏭️ Animation already exists, skipping generation: \(animURL.path)")
                        return animURL
                    }
                } else {
                    let rootFolder = config.outputdirectory ?? video.url.deletingLastPathComponent()
                    let outputDir = config.generateOutputDirectory(rootDirectory: rootFolder, videoInput: video, referenceDate: referenceDate)
                    let originalFilename = video.url.deletingPathExtension().lastPathComponent
                    let filename = config.generateFilename(originalFilename: originalFilename, videoInput: video)
                    let mosaicURL = outputDir.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: mosaicURL.path) {
                        if config.gifMode == .withMosaic {
                            let animationURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)
                            if !FileManager.default.fileExists(atPath: animationURL.path) {
                                let asset = AVURLAsset(url: video.url)
                                let duration = try await asset.load(.duration).seconds
                                guard duration.isFinite, duration > 0 else { throw MosaicError.invalidVideo("Invalid duration") }
                                // The same layout `planMosaic` computes (P2): one shared helper.
                                let (_, layout) = try makeLayout(for: video, duration: duration, config: config,
                                                                 forIphone: forIphone, progressHandler: nil)
                                // `config.overwrite` is false on this path.
                                try await exportAnimation(for: video, asset: asset, layout: layout, config: config, to: animationURL)
                            }
                        }
                        return mosaicURL
                    }
                }
            }
    
            let plan = try await planMosaic(for: video, config: config, forIphone: forIphone,
                                            progressHandler: attemptProgressHandler)
            let asset = plan.asset
            let layout = plan.layout
            let plannedConfig = plan.config

            let layoutTime = CFAbsoluteTimeGetCurrent()
            let executionTime = layoutTime - startTime
            logger.debug("layout process in \(executionTime) seconds")

            // Animation-only mode: skip mosaic entirely
            if plannedConfig.gifMode == .gifOnly {
                let animURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)
                try FileManager.default.createDirectory(
                    at: animURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try await exportAnimation(for: video, asset: asset, layout: layout, config: plannedConfig, to: animURL)
                logger.debug("💾 Animation-only saved to: \(animURL.path)")
                return animURL
            }

            let mosaic = try await composeMosaic(for: video, plan: plan, forIphone: forIphone,
                                                 progressHandler: attemptProgressHandler)

            attemptProgressHandler?(MosaicGenerationProgress(
                video: video,
                progress: 0.9,
                status: .savingMosaic
            ))
            // Save the mosaic to disk
            let mosaicURL = try await saveMosaic(
                mosaic,
                for: video,
                config: config,
                forIphone: forIphone,
                referenceDate: referenceDate
            )

            attemptProgressHandler?(MosaicGenerationProgress(
                video: video,
                progress: 0.999,
                status: .savingMosaic
            ))

            // Generate animated image alongside the mosaic when requested
            if plannedConfig.gifMode == .withMosaic {
                let animURL = config.animatedOutputURL(for: video, referenceDate: referenceDate)

                if FileManager.default.fileExists(atPath: animURL.path) && !plannedConfig.overwrite {
                    logger.debug("⏭️ Animation already exists, skipping animation save: \(animURL.path)")
                } else {
                    try await exportAnimation(for: video, asset: asset, layout: layout, config: plannedConfig, to: animURL)
                    logger.debug("💾 Animation saved to: \(animURL.path)")
                }
            }

            return mosaicURL
        }

        generationTasks[videoID, default: [:]][attemptID] = task
        defer {
            generationTasks[videoID]?[attemptID] = nil
            if generationTasks[videoID]?.isEmpty == true { generationTasks[videoID] = nil }
            releaseProgressHandler(videoID: videoID, revision: handlerRevision)
        }

        // Bridge caller cancellation into the internal task: without this,
        // cancelling the awaiting task (e.g. a coordinator wrapper) would leave
        // the generation running to completion in the background.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Generate a mosaic image for a video without saving to disk
    /// - Parameters:
    ///   - video: The video to generate a mosaic for
    ///   - config: The configuration for mosaic generation
    ///   - forIphone: Whether to use iPhone-optimized layout
    /// - Returns: The generated mosaic as a CGImage
    public func generateMosaicImage(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool = false) async throws -> CGImage {
        signposter.emitEvent("generateMosaicImage")
        let intervalState = signposter.beginInterval("generateMosaicImage")
        defer { signposter.endInterval("generateMosaicImage", intervalState) }
        try config.validate()
        let videoID = video.id
        let attemptID = UUID()
        layoutProcessor.mosaicAspectRatio = config.layout.aspectRatio.ratio

        // Run the generation in a tracked task so cancel(for:) / cancelAll() reach
        // in-memory image generation the same way they reach file generation.
        let attemptProgressHandler = progressHandlers[videoID]
        let handlerRevision = progressHandlerRevisions[videoID]
        let task = Task<CGImage, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            defer { trackPerformance(startTime: startTime) }
            try Task.checkCancellation()
            return try await performMosaicImageGeneration(for: video, config: config, forIphone: forIphone, attemptProgressHandler: attemptProgressHandler)
        }

        imageGenerationTasks[videoID, default: [:]][attemptID] = task
        defer {
            imageGenerationTasks[videoID]?[attemptID] = nil
            if imageGenerationTasks[videoID]?.isEmpty == true { imageGenerationTasks[videoID] = nil }
            releaseProgressHandler(videoID: videoID, revision: handlerRevision)
        }

        // Bridge caller cancellation into the tracked task (see generate(for:config:forIphone:)).
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Body of `generateMosaicImage(for:config:forIphone:)` — runs inside the tracked task.
    private func performMosaicImageGeneration(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool, attemptProgressHandler: (@Sendable (MosaicGenerationProgress) -> Void)?) async throws -> CGImage {
        signposter.emitEvent("performMosaicImageGeneration")
        let intervalState = signposter.beginInterval("performMosaicImageGeneration")
        defer { signposter.endInterval("performMosaicImageGeneration", intervalState) }
        let plan = try await planMosaic(for: video, config: config, forIphone: forIphone,
                                        progressHandler: attemptProgressHandler)
        let mosaic = try await composeMosaic(for: video, plan: plan, forIphone: forIphone,
                                             progressHandler: attemptProgressHandler)

        attemptProgressHandler?(MosaicGenerationProgress(
            video: video,
            progress: 1.0,
            status: .completed
        ))

        try Task.checkCancellation()
        return mosaic
    }

    // MARK: - Shared composition path (S-2)

    /// Inputs of one mosaic composition, resolved once per attempt.
    private struct MosaicPlan {
        let asset: AVURLAsset
        let layout: MosaicLayout
        /// The caller's configuration with the aspect ratio snapped to the computed layout.
        let config: MosaicConfiguration
    }

    /// Validates the source, reports `.countingThumbnails` and `.computingLayout`, and computes
    /// the layout. Shared by `generate(for:config:forIphone:)` and
    /// `generateMosaicImage(for:config:forIphone:)`.
    private func planMosaic(
        for video: VideoInput,
        config: MosaicConfiguration,
        forIphone: Bool,
        progressHandler: (@Sendable (MosaicGenerationProgress) -> Void)?
    ) async throws -> MosaicPlan {
        let asset = AVURLAsset(url: video.url)
        let duration: Double
        if let known = video.duration { duration = known } else { duration = try await asset.load(.duration).seconds }
        guard duration.isFinite, duration > 0, config.width > 0, config.width <= 16_384, (video.width ?? 1).isFinite, (video.height ?? 1).isFinite, (video.width ?? 1) > 0, (video.height ?? 1) > 0 else { throw MosaicError.invalidVideo("Invalid duration or dimensions") }
        if duration < 5.0 {
            throw MosaicError.invalidVideo("video too short")
        }
        let (frameCount, layout) = try makeLayout(
            for: video, duration: duration, config: config, forIphone: forIphone, progressHandler: progressHandler
        )
        logger.debug("📐 Generation plan for \(video.title) - width: \(config.width), density: \(config.density.name), requested frames: \(frameCount), layout positions: \(layout.positions.count), mosaic size: \(Int(layout.mosaicSize.width))x\(Int(layout.mosaicSize.height))")

        var adjustedConfig = config
        adjustedConfig.updateAspectRatio(new: AspectRatio.findNearest(to: layout.mosaicSize))
        return MosaicPlan(asset: asset, layout: layout, config: adjustedConfig)
    }

    /// The layout type that is actually calculated.
    ///
    /// An explicit rows × columns request wins over `forIphone` (P1): `forIphone` still selects the
    /// iPhone header styling, but it must not silently replace the user's grid with the iPhone
    /// layout.
    static func effectiveLayoutType(config: MosaicConfiguration, forIphone: Bool) -> LayoutType {
        if config.layout.layoutType == .fixedGrid { return .fixedGrid }
        return forIphone ? .iphone : config.layout.layoutType
    }

    /// How frames are spread over the video: evenly for a fixed grid (read left to right, equal
    /// time steps), the weighted 20/60/20 split for every other layout (KB rules card #9).
    static func samplingPolicy(for config: MosaicConfiguration) -> ThumbnailProcessor.FrameSamplingPolicy {
        config.layout.layoutType == .fixedGrid ? .uniform : .weighted
    }

    /// The crop a fixed grid in `.crop` mode applies to every frame: the drawn frame's aspect (the
    /// cell minus the render inset). `nil` for every other layout or fit, and when the cell is
    /// already within `aspectTolerance` of the video (then the frame is simply stretched).
    static func frameCrop(for video: VideoInput, layout: MosaicLayout, config: MosaicConfiguration) -> ThumbnailProcessor.FrameCrop? {
        guard config.layout.layoutType == .fixedGrid, let grid = config.layout.grid, grid.fit == .crop,
              let width = video.width, let height = video.height, width > 0, height > 0,
              let cell = layout.thumbnailSizes.first else { return nil }
        let inset = max(0, config.layout.spacing.rounded() - 4)
        let frameWidth = cell.width - inset
        let frameHeight = cell.height - inset
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        let aspect = frameWidth / frameHeight
        let source = width / height
        let ratio = aspect / source
        guard max(ratio, 1 / ratio) - 1 > grid.aspectTolerance else { return nil }
        return ThumbnailProcessor.FrameCrop(aspect: aspect, sourceAspect: source)
    }

    /// The most distinct frames a video can fill: 90 % of `duration × frameRate`, since frames are
    /// sampled over the middle 90 % of the video. `nil` when the frame rate is unknown.
    static func distinctFrameBudget(duration: Double, frameRate: Double?) -> Int? {
        guard let frameRate, frameRate.isFinite, frameRate > 0, duration.isFinite, duration > 0 else { return nil }
        return Int((0.9 * duration * frameRate).rounded(.down))
    }

    /// An upper bound for the height the header and the ColorDNA strip add on top of the cells,
    /// so a grid never plans a canvas the pipeline would reject (§3.4 of the fixed-grid spec).
    /// Also used by ``LayoutType/uneven``. A fixed header taller than the estimate reserves its
    /// own height.
    static func fixedGridReservedHeight(for config: MosaicConfiguration) -> Int {
        var header = config.includeMetadata ? Int((0.10 * Double(config.width)).rounded(.up)) + 32 : 0
        if config.includeMetadata, case .fixed(let height) = config.overlay.header.height { header = max(header, height) }
        let strip = config.overlay.colorDNA.show ? Int(config.overlay.colorDNA.height.rounded(.up)) : 0
        return header + strip
    }

    /// The exact height the header and the ColorDNA strip add for the fixed-aspect grid modes, so the
    /// planner can subtract it and the final image keeps the configured aspect. The header is sized
    /// from `W/20` (see `makeMetadataHeader`), so it does not depend on the cells.
    func fixedGridOverlayHeight(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) -> Int {
        let width = LayoutProcessor.fixedGridCanvasWidth(requestedWidth: config.width, mosaicAspectRatio: config.layout.aspectRatio)
        let header = config.includeMetadata
            ? thumbnailProcessor.metadataHeaderHeight(
                for: video, width: width, thumbnailHeight: CGFloat(width) / 20,
                forIphone: forIphone, headerConfig: config.overlay.header)
            : 0
        let strip = config.overlay.colorDNA.show ? Int(ColorDNAConfig.clampedHeight(config.overlay.colorDNA.height)) : 0
        return header + strip
    }

    /// The frame count and the layout for one video: shared by `planMosaic` and the backfill path
    /// of `generate`, so both always compute the same layout (P2).
    ///
    /// For a fixed grid the plan is checked first: an infeasible request throws a typed error
    /// before any progress event and before anything is decoded.
    private func makeLayout(
        for video: VideoInput,
        duration: Double,
        config: MosaicConfiguration,
        forIphone: Bool,
        progressHandler: (@Sendable (MosaicGenerationProgress) -> Void)?
    ) throws -> (frameCount: Int, layout: MosaicLayout) {
        let layoutType = Self.effectiveLayoutType(config: config, forIphone: forIphone)
        let grid = layoutType == .fixedGrid ? config.layout.grid : nil
        var aspectRatio = (video.width ?? 1.0) / (video.height ?? 1.0)
        let spacing = config.layout.spacing
        let reservedHeight = layoutType == .fixedGrid || layoutType == .uneven ? Self.fixedGridReservedHeight(for: config) : 0
        let fixedAspect = layoutType == .fixedGrid && (config.layout.grid?.fit ?? .adaptCanvas) != .adaptCanvas
        let overlayHeight = fixedAspect ? fixedGridOverlayHeight(for: video, config: config, forIphone: forIphone) : 0

        if layoutType == .fixedGrid {
            guard let grid else { throw MosaicError.invalidConfiguration("The fixedGrid layout needs LayoutConfiguration.grid (rows and columns)") }
            guard let width = video.width, let height = video.height, width > 0, height > 0 else {
                throw MosaicError.invalidVideo(FixedGridIssue.unknownSourceAspect.explanation)
            }
            aspectRatio = width / height
            if forIphone { logger.info("A fixedGrid layout takes precedence over forIphone for \(video.title, privacy: .public)") }
            if case .infeasible(let issue, _) = layoutProcessor.planFixedGrid(
                grid, sourceAspectRatio: aspectRatio, mosaicAspectRatio: config.layout.aspectRatio,
                mosaicWidth: config.width, spacing: spacing, reservedHeight: reservedHeight,
                overlayHeight: overlayHeight
            ) {
                throw MosaicError.invalidConfiguration(issue.explanation)
            }
            // More cells than distinct frames would repeat pictures by construction (T3).
            let cells = grid.rows * grid.columns
            if let budget = Self.distinctFrameBudget(duration: duration, frameRate: video.frameRate) {
                if cells > budget {
                    throw MosaicError.invalidVideo(
                        "This video has about \(budget) distinct frames (\(Int(duration.rounded())) s at \(String(format: "%g", video.frameRate ?? 0)) fps); a \(grid.rows) × \(grid.columns) grid needs \(cells). Use fewer cells"
                    )
                }
            } else {
                logger.debug("Frame rate unknown for \(video.title, privacy: .public): cannot check that \(cells) cells have distinct frames")
            }
            // Cells closer than the extraction tolerance snap to the same keyframe in fast mode (T4).
            if !config.useAccurateTimestamps, duration / Double(cells) < 0.5 {
                logger.warning("A \(cells)-cell grid takes a frame every \(String(format: "%.2f", duration / Double(cells))) s but fast timestamps tolerate 1 s: neighbors may repeat. Use useAccurateTimestamps for \(video.title, privacy: .public)")
            }
        }

        progressHandler?(MosaicGenerationProgress(video: video, progress: 0.00, status: .countingThumbnails))
        let frameCount = layoutProcessor.calculateThumbnailCount(
            duration: duration,
            width: config.width,
            density: config.density,
            layoutType: layoutType,
            videoAR: aspectRatio,
            grid: grid
        )

        progressHandler?(MosaicGenerationProgress(video: video, progress: 0.00, status: .computingLayout))
        let layout = layoutProcessor.calculateLayout(
            originalAspectRatio: aspectRatio,
            mosaicAspectRatio: config.layout.aspectRatio,
            thumbnailCount: frameCount,
            mosaicWidth: config.width,
            density: config.density,
            layoutType: layoutType,
            grid: grid,
            spacing: spacing,
            reservedHeight: reservedHeight,
            overlayHeight: overlayHeight
        )
        return (frameCount, layout)
    }

    /// The metadata header for `video`, or `nil` when `config.includeMetadata` is off.
    ///
    /// `.colorPalette` swatches need colors before the header is drawn, so a few frames are
    /// sampled first. That step is skipped, at no cost, unless the header asks for the field (I-10).
    /// Internal (not private) so tests can check the header without the random mosaic background.
    func makeMetadataHeader(
        for video: VideoInput,
        layout: MosaicLayout,
        config: MosaicConfiguration,
        forIphone: Bool
    ) async throws -> CGImage? {
        guard config.includeMetadata else { return nil }
        let headerConfig = config.overlay.header
        var swatchColors: [CGColor] = []
        if let swatchCount = headerConfig.paletteSwatchCount {
            do {
                swatchColors = try await thumbnailProcessor.paletteSwatchColors(
                    url: video.url, duration: video.duration, count: swatchCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Palette swatches skipped for \(video.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // The header's minimum height is a fraction of the cell height, which suits dense layouts
        // with small cells. A grid can have huge cells (a 1 × 1 grid at 5120 px has 2,880 px
        // ones), so for grids the cell height is capped at W/20, about the cell size `.custom`
        // makes at that width.
        // The fixed-aspect modes size it from exactly W/20, so the planner can know the header
        // height before the cells exist (`fixedGridOverlayHeight`).
        let fixedAspect = config.layout.layoutType == .fixedGrid && (config.layout.grid?.fit ?? .adaptCanvas) != .adaptCanvas
        let cellHeight = fixedAspect
            ? layout.mosaicSize.width / 20
            : config.layout.layoutType == .fixedGrid
                ? min(layout.thumbnailSize.height, layout.mosaicSize.width / 20)
                : layout.thumbnailSize.height
        return thumbnailProcessor.createMetadataHeader(
            for: video,
            width: Int(layout.mosaicSize.width),
            thumbnailHeight: cellHeight,
            forIphone: forIphone,
            headerConfig: headerConfig,
            swatchColors: swatchColors
        ) as CGImage?
    }

    /// Composes the mosaic image: metadata header, streamed frames through Metal (progress
    /// `.creatingMosaic`, 0.7 → 0.999), then the ColorDNA strip and the watermark.
    private func composeMosaic(
        for video: VideoInput,
        plan: MosaicPlan,
        forIphone: Bool,
        progressHandler: (@Sendable (MosaicGenerationProgress) -> Void)?
    ) async throws -> CGImage {
        let layout = plan.layout
        let config = plan.config
        let overlayConfig = config.overlay

        let metadataHeader = try await makeMetadataHeader(
            for: video, layout: layout, config: config, forIphone: forIphone
        )

        let colorCollector = overlayConfig.colorDNA.show ? FrameColorCollector() : nil
        let processedStream = thumbnailProcessor.processedFramesStream(
            from: video.url, layout: layout, asset: plan.asset,
            accurate: config.useAccurateTimestamps,
            labelConfig: overlayConfig.frameLabel,
            sampling: Self.samplingPolicy(for: config),
            crop: Self.frameCrop(for: video, layout: layout, config: config),
            collectColor: { index, image in
                if let collector = colorCollector {
                    await collector.store(OverlayProcessor.averageColor(of: image), at: index)
                }
            }
        )

        var mosaic = try await metalProcessor.generateMosaicStream(
            stream: processedStream,
            layout: layout,
            metadata: VideoMetadata(
                codec: video.metadata.codec,
                bitrate: video.metadata.bitrate,
                custom: video.metadata.custom
            ),
            config: config,
            metadataHeader: metadataHeader,
            forIphone: forIphone,
            progressHandler: { @Sendable progress in
                let scaledProgress = 0.7 + (0.299 * progress)
                progressHandler?(MosaicGenerationProgress(
                    video: video,
                    progress: scaledProgress,
                    status: .creatingMosaic
                ))
            }
        )

        if overlayConfig.colorDNA.show, let collector = colorCollector {
            let frameColors = await collector.orderedColors(count: layout.thumbCount)
            if let dnaImage = OverlayProcessor.applyColorDNA(
                to: mosaic, frameColors: frameColors, config: overlayConfig.colorDNA) {
                mosaic = dnaImage
            } else {
                // The mosaic is kept without the strip; say so instead of dropping it silently (I-18).
                logger.warning("ColorDNA strip requested for \(video.title, privacy: .public) but not drawn (\(frameColors.count) frame colors)")
            }
        }

        if let wmConfig = overlayConfig.watermark {
            if let watermarked = OverlayProcessor.applyWatermark(to: mosaic, config: wmConfig) {
                mosaic = watermarked
            } else {
                logger.warning("Watermark requested for \(video.title, privacy: .public) but not drawn")
            }
        }
        return mosaic
    }

    /// Extracts `layout.thumbCount` frames and writes the animated export to `url`, used by the
    /// three animation sites in `generate(for:config:forIphone:)`.
    private func exportAnimation(
        for video: VideoInput,
        asset: AVURLAsset,
        layout: MosaicLayout,
        config: MosaicConfiguration,
        to url: URL
    ) async throws {
        let frames = try await thumbnailProcessor.extractAnimationFrames(
            from: video.url,
            asset: asset,
            count: layout.thumbCount,
            gifSize: config.gifSize,
            accurate: config.useAccurateTimestamps,
            policy: Self.samplingPolicy(for: config)
        )
        try AnimatedGifGenerator.save(frames: frames, to: url, format: config.animatedFormat,
                                      frameDelay: 1.0 / config.gifFps, overwrite: config.overwrite)
    }

    private func releaseProgressHandler(videoID: UUID, revision: UUID?) {
        signposter.emitEvent("releaseProgressHandler")
        let intervalState = signposter.beginInterval("releaseProgressHandler")
        defer { signposter.endInterval("releaseProgressHandler", intervalState) }
        guard generationTasks[videoID] == nil, imageGenerationTasks[videoID] == nil,
              progressHandlerRevisions[videoID] == revision else { return }
        progressHandlers[videoID] = nil
        progressHandlerRevisions[videoID] = nil
    }

    /// Cancel mosaic generation for a specific video
    /// - Parameter video: The video to cancel mosaic generation for
    public func cancel(for video: VideoInput) {
        signposter.emitEvent("cancel")
        let intervalState = signposter.beginInterval("cancel")
        defer { signposter.endInterval("cancel", intervalState) }
        generationTasks[video.id]?.values.forEach { $0.cancel() }
        generationTasks[video.id] = nil
        imageGenerationTasks[video.id]?.values.forEach { $0.cancel() }
        imageGenerationTasks[video.id] = nil
    }

    /// Cancel all ongoing mosaic generation operations
    public func cancelAll() {
        signposter.emitEvent("cancelAll")
        let intervalState = signposter.beginInterval("cancelAll")
        defer { signposter.endInterval("cancelAll", intervalState) }
        generationTasks.values.forEach { $0.values.forEach { $0.cancel() } }
        generationTasks.removeAll()
        imageGenerationTasks.values.forEach { $0.values.forEach { $0.cancel() } }
        imageGenerationTasks.removeAll()
    }
    
    /// Set a progress handler for a specific video
    /// - Parameters:
    ///   - video: The video to set the progress handler for
    ///   - handler: The progress handler
    public func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void) {
             signposter.emitEvent("setProgressHandler")
             let intervalState = signposter.beginInterval("setProgressHandler")
             defer { signposter.endInterval("setProgressHandler", intervalState) }
             progressHandlerRevisions[video.id] = UUID()
             progressHandlers[video.id] = handler
        }
    
    
    /// Get performance metrics for the Metal mosaic generator
    /// - Returns: A dictionary of performance metrics
    public func getPerformanceMetrics() -> [String: Any] {
        signposter.emitEvent("getPerformanceMetrics")
        let intervalState = signposter.beginInterval("getPerformanceMetrics")
        defer { signposter.endInterval("getPerformanceMetrics", intervalState) }
        var metrics: [String: Any] = [
            "averageGenerationTime": generationCount > 0 ? totalGenerationTime / Double(generationCount) : 0,
            "totalGenerationTime": totalGenerationTime,
            "generationCount": generationCount,
            "lastGenerationTime": lastGenerationTime
        ]
        
        // Add Metal processor metrics
        let metalMetrics = metalProcessor.getPerformanceMetrics()
        for (key, value) in metalMetrics {
            metrics["metal_\(key)"] = value
        }
        
        return metrics
    }
    
    // MARK: - Private Methods
    
    /// Save a mosaic image to disk
    /// - Parameters:
    ///   - mosaic: The mosaic image to save
    ///   - video: The video the mosaic was generated for
    ///   - config: The mosaic configuration
    ///   - referenceDate: The date/time used to resolve `{date}`/`{time}` tokens
    ///     in `config.outputDirectoryTemplate`. Callers should pass the same
    ///     `referenceDate` used for any earlier existence check on this same
    ///     save operation so a `{time}` token resolves to the same directory.
    /// - Returns: The URL of the saved mosaic
    private func saveMosaic(
        _ mosaic: CGImage,
        for video: VideoInput,
        config: MosaicConfiguration,
        forIphone: Bool = false,
        referenceDate: Date = Date()
    ) async throws -> URL {
        let state = signposter.beginInterval("Save Mosaic")
        defer { signposter.endInterval("Save Mosaic", state) }
        signposter.emitEvent("saving mosaic","name : \(video.url.lastPathComponent)")

        // Determine base output directory
        var baseOutputDirectory: URL
        var mosaicURL: URL!

        // Use the video's folder when no explicit output directory is configured.
        let rootFolder = config.outputdirectory ?? video.url.deletingLastPathComponent()

        // Generate structured path: {root}/{service}/{creator}/{configHash}/
        baseOutputDirectory = config.generateOutputDirectory(rootDirectory: rootFolder, videoInput: video, referenceDate: referenceDate)

        let didStartAccessingBaseDirectory = baseOutputDirectory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingBaseDirectory {
                baseOutputDirectory.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: baseOutputDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)

        // Generate filename using configuration method
        let videoURL = video.url
        let originalFilename = videoURL.deletingPathExtension().lastPathComponent
        let filename = config.generateFilename(originalFilename: originalFilename, videoInput: video)

        mosaicURL = baseOutputDirectory.appendingPathComponent(filename)

        let transaction = try OutputTransaction(finalURL: mosaicURL, overwrite: config.overwrite)
        defer { transaction.discard() }
        try Task.checkCancellation()
        
        if config.format == .webp {
            let didStartAccessingDirectory = mosaicURL.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer {
                if didStartAccessingDirectory {
                    mosaicURL.deletingLastPathComponent().stopAccessingSecurityScopedResource()
                }
            }
            guard let encoder = MosaicKitWebPSupport.encoder else {
                throw MosaicKitWebPError.encoderNotRegistered
            }
            let data = try encoder.encodeStillWebP(mosaic, quality: Float(config.compressionQuality * 100))
            try data.write(to: transaction.stagingURL)
            try transaction.commit()
            return mosaicURL
        }

        let identifier: CFString
        switch config.format {
        case .jpeg:
            identifier = UTType.jpeg.identifier as CFString
        case .png:
            identifier = UTType.png.identifier as CFString
        case .heif:
            identifier = UTType.heic.identifier as CFString
        case .webp:
            identifier = UTType.webP.identifier as CFString
        }

        // Use security scoped resource for HEIF
        var didStartAccessingDirectory = false
        if config.format == .heif {
            let directory = mosaicURL.deletingLastPathComponent()
            didStartAccessingDirectory = directory.startAccessingSecurityScopedResource()
        }
        defer {
            if didStartAccessingDirectory {
                mosaicURL.deletingLastPathComponent().stopAccessingSecurityScopedResource()
            }
        }

        guard let destination = CGImageDestinationCreateWithURL(
            transaction.stagingURL as CFURL,
            identifier,
            1,
            nil
        ) else {
            throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
        }

        var options: [String: Any] = [:]
        if config.format == .jpeg || config.format == .heif {
            options[kCGImageDestinationLossyCompressionQuality as String] = config.compressionQuality
        }
        if config.format == .heif {
            options[kCGImageDestinationEmbedThumbnail as String] = true
            options[kCGImagePropertyHasAlpha as String] = false
        }

        CGImageDestinationAddImage(destination, mosaic, options as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            throw MosaicError.saveFailed(mosaicURL, NSError(domain: "com.mosaicKit", code: -1))
        }

        try transaction.commit()
        return mosaicURL
    }
    
    /// Track performance metrics
    /// - Parameter startTime: The start time of the operation
    private func trackPerformance(startTime: CFAbsoluteTime) {
        signposter.emitEvent("trackPerformance")
        let intervalState = signposter.beginInterval("trackPerformance")
        defer { signposter.endInterval("trackPerformance", intervalState) }
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        lastGenerationTime = executionTime
        totalGenerationTime += executionTime
        generationCount += 1
    }
}
