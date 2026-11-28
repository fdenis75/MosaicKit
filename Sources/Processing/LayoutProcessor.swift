import Foundation
import CoreGraphics
import OSLog
import Synchronization
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Handles mosaic layout calculations and optimization
// @available(macOS 26, iOS 26, *)
public final class LayoutProcessor {
    let logger = Logger(subsystem: "com.mosaicKit", category: "layout-processing")
    let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "layout-processor")
    private let stateLock = NSRecursiveLock()
    private var storedAspectRatio: CGFloat
    public var mosaicAspectRatio: CGFloat {
        get { stateLock.withLock { storedAspectRatio } }
        set { stateLock.withLock { storedAspectRatio = newValue.isFinite && newValue > 0 ? newValue : 16.0 / 9.0 } }
    }
    private var layoutCache: [String: MosaicLayout] = [:]

    
    /// Get the screen with the largest size
    private func getLargestScreen() -> (size: CGSize, scale: CGFloat)? {
        let state = signposter.beginInterval("Get Largest Screen")
        defer { signposter.endInterval("Get Largest Screen", state) }
        
        #if canImport(AppKit)
        let screens = NSScreen.screens
        guard let largestScreen = screens.max(by: { screen1, screen2 in
            let size1 = screen1.frame.size
            let size2 = screen2.frame.size
            return (size1.width * size1.height) < (size2.width * size2.height)
        }) else { return nil }
        
        return (largestScreen.visibleFrame.size, largestScreen.backingScaleFactor)
        #elseif canImport(UIKit)
        // iOS doesn't support multiple screens in the same way, so return main screen
        let mainScreen = UIScreen.main
        return (mainScreen.bounds.size, mainScreen.scale)
        #else
        return nil
        #endif
    }
    
    /// Initialize a new layout processor
    public init(aspectRatio: CGFloat = 16.0 / 9.0) {
        let state = signposter.beginInterval("Initialize Layout Processor")
        defer { signposter.endInterval("Initialize Layout Processor", state) }
        
        self.storedAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
    }
    
    /// Update the mosaic aspect ratio
    /// - Parameter ratio: New aspect ratio to use
    public func updateAspectRatio(_ ratio: CGFloat) {
        let state = signposter.beginInterval("Update Aspect Ratio")
        defer { signposter.endInterval("Update Aspect Ratio", state) }
        
        self.mosaicAspectRatio = ratio
        stateLock.withLock { layoutCache.removeAll() }
    }
    
    /// Calculate optimal mosaic layout
    /// - Parameters:
    ///   - originalAspectRatio: Aspect ratio of the original video
    ///   - mosaicAspectRatio: The mosaic's aspect preset
    ///   - thumbnailCount: Number of thumbnails to include
    ///   - mosaicWidth: Desired width of the mosaic
    ///   - density: Density configuration for layout
    ///   - layoutType: The layout algorithm
    ///   - grid: The rows, columns and fit mode for ``LayoutType/fixedGrid``; ignored otherwise
    ///   - spacing: `LayoutConfiguration.spacing`, read by ``LayoutType/fixedGrid``
    ///   - reservedHeight: ``LayoutType/fixedGrid`` with ``GridFitMode/adaptCanvas``, and
    ///     ``LayoutType/uneven``: upper bound of the header and ColorDNA strip height
    ///   - overlayHeight: ``LayoutType/fixedGrid`` in a fixed-aspect mode: exact header and
    ///     ColorDNA strip height
    /// - Returns: Optimal layout for the mosaic; an empty layout when a grid cannot be laid out
    ///   (``planFixedGrid(_:sourceAspectRatio:mosaicAspectRatio:mosaicWidth:spacing:reservedHeight:overlayHeight:)`` says why)
    public func calculateLayout(
        originalAspectRatio: CGFloat,
        mosaicAspectRatio: AspectRatio,
        thumbnailCount: Int,
        mosaicWidth: Int,
        density: DensityConfig,
        layoutType: LayoutType,
        grid: GridSpecification? = nil,
        spacing: CGFloat = LayoutConfiguration.default.spacing,
        reservedHeight: Int = 0,
        overlayHeight: Int = 0
    ) -> MosaicLayout {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard originalAspectRatio.isFinite, originalAspectRatio >= 0.01, originalAspectRatio <= 100,
              thumbnailCount > 0, thumbnailCount <= 100_000, mosaicWidth > 0, mosaicWidth <= 16_384 else {
            return MosaicLayout(rows: 0, cols: 0, thumbnailSize: .zero, positions: [], thumbCount: 0,
                                thumbnailSizes: [], mosaicSize: .zero)
        }
        storedAspectRatio = mosaicAspectRatio.ratio
        logger.debug("🎯 Starting layout calculation - AR: \(originalAspectRatio), Count: \(thumbnailCount), Width: \(mosaicWidth), target AR: \(self.mosaicAspectRatio)")
        logger.debug("⚙️ Layout mode: \(layoutType.rawValue), Density: \(density.name)")

        var cacheKey = "\(mosaicAspectRatio.rawValue)-\(originalAspectRatio)-\(thumbnailCount)-\(mosaicWidth)-\(density.name)-\(layoutType.rawValue)"
        if layoutType == .fixedGrid {
            // The grid result depends on all of these, none of which the key above has. Existing
            // layouts keep their keys byte for byte.
            if let grid {
                cacheKey += "-grid=\(grid.rows)x\(grid.columns)-\(grid.fit.rawValue)-\(grid.aspectTolerance)-\(grid.minimumFill)-sp=\(spacing)-rh=\(reservedHeight)-oh=\(overlayHeight)"
            } else {
                cacheKey += "-grid=none"
            }
        }
        if layoutType == .uneven {
            // The height limit depends on the reserve; existing layouts keep their keys.
            cacheKey += "-rh=\(reservedHeight)"
        }
        if layoutType != .auto, let cached = layoutCache[cacheKey] { return cached }

        let layout: MosaicLayout

        switch layoutType {
        case .auto:
            // The screen only gives the shape; width and count are the configured ones.
            let screenAspect = getLargestScreen().map { $0.size.width / max($0.size.height, 1) }
            layout = calculateAutoLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth,
                screenAspect: screenAspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? mosaicAspectRatio.ratio
            )
        case .classic:
            layout = calculateClassicLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth
            )
        case .fixedGrid:
            // Explicit, so it can never fall through to `.custom`. Without a grid, or when the
            // grid cannot be laid out, this is the empty layout like other invalid input; the
            // generator plans with `planFixedGrid` first and reports the reason.
            guard let grid, case .layout(let planned, _, _) = planFixedGrid(
                grid, sourceAspectRatio: originalAspectRatio, mosaicAspectRatio: mosaicAspectRatio,
                mosaicWidth: mosaicWidth, spacing: spacing, reservedHeight: reservedHeight,
                overlayHeight: overlayHeight
            ) else {
                return MosaicLayout(rows: 0, cols: 0, thumbnailSize: .zero, positions: [], thumbCount: 0,
                                    thumbnailSizes: [], mosaicSize: .zero)
            }
            layout = planned
        case .uneven:
            layout = calculateUnevenLayout(
                originalAspectRatio: originalAspectRatio,
                mosaicAspectRatio: mosaicAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth,
                density: density,
                reservedHeight: reservedHeight
            )
        case .custom:
            layout = calculateCustomLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth,
                mosaicAspectRatio: mosaicAspectRatio
            )
        default:
            // Only the deprecated `.iphone` is left (not named, to keep this file warning-free).
            layout = calculateiPhoneLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth
            )
        }

        if layoutCache.count >= 64 { layoutCache.removeAll(keepingCapacity: true) }
        if layoutType != .auto { layoutCache[cacheKey] = layout }
        return layout
    }






    func calculateClassicLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int,
        mosaicWidth: Int
    ) -> MosaicLayout {
        uniformGrid(originalAspectRatio: originalAspectRatio, thumbnailCount: thumbnailCount,
                    mosaicWidth: mosaicWidth, aspect: mosaicAspectRatio)
    }
    
    // MARK: - Helper Methods

    /// Calculate thumbnail count based on video duration and width
    /// - Parameters:
    ///   - duration: Video duration in seconds
    ///   - width: Mosaic width
    ///   - density: Density configuration
    ///   - layoutType: The layout algorithm; ``LayoutType/auto`` counts from the screen size
    ///   - videoAR: The video's aspect ratio (width / height)
    ///   - grid: For ``LayoutType/fixedGrid``, the count is exactly `rows × columns`
    /// - Returns: Optimal number of thumbnails
    public func calculateThumbnailCount(
        duration: Double,
        width: Int,
        density: DensityConfig,
        layoutType: LayoutType = .custom,
        videoAR: Double,
        grid: GridSpecification? = nil
    ) -> Int {
        logger.debug("🔢 Calculating thumbnail count - Duration: \(duration)s, Width: \(width)")
        
        guard duration.isFinite, duration > 0, width > 0, width <= 16_384, videoAR.isFinite, videoAR >= 0.01, videoAR <= 100 else { return 0 }
        // A grid asks for exactly rows × columns frames, whatever the density. Checked before the
        // short-video rule below, which would answer 4.
        if layoutType == .fixedGrid {
            guard let grid,
                  (1...GridSpecification.maximumAxisCount).contains(grid.rows),
                  (1...GridSpecification.maximumAxisCount).contains(grid.columns) else { return 0 }
            let cells = grid.rows * grid.columns
            return cells <= GridSpecification.maximumCellCount ? cells : 0
        }
        if duration < 5 { return 4 }
        
        let base = Double(width) / 200.0
        let k = 10.0
        let rawCount = base + k * log(duration)
        let totalCount = Int(min(max(rawCount * density.factor, 4), 800))
        logger.debug("📊 Calculated count: \(totalCount) (raw: \(rawCount))")
        return totalCount
    
    }
    
    
    private func calculateiPhoneLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int,
        mosaicWidth: Int // Parameter kept for signature consistency, but fixed internally
    ) -> MosaicLayout {
        let state = signposter.beginInterval("Calculate iPhone Layout")
        defer { signposter.endInterval("Calculate iPhone Layout", state) }
        logger.debug("📱 Calculating specific iPhone layout")

        let fixedWidth: CGFloat = 1200.0
        let maxHeight: CGFloat = 8000.0
        let cols: Int = 1
        let spacing: CGFloat = 4.0

        // Calculate thumbnail dimensions based on fixed width and 2 columns
        let availableWidth = fixedWidth - (spacing * CGFloat(cols - 1))
        let thumbWidth = availableWidth / CGFloat(cols)
        let thumbHeight = thumbWidth / originalAspectRatio

        // Calculate max rows that fit within maxHeight
        let maxRows = Int(floor((maxHeight + spacing) / (thumbHeight + spacing)))

        // Determine actual thumbnail count based on input and max height
        let maxPossibleThumbs = maxRows * cols
        let actualThumbCount = min(thumbnailCount, maxPossibleThumbs)

        // Calculate actual rows needed
        let actualRows = Int(ceil(Double(actualThumbCount) / Double(cols)))

        // Calculate final mosaic height
        let finalMosaicHeight = (CGFloat(actualRows) * thumbHeight) + (spacing * CGFloat(max(0, actualRows - 1)))

        // Generate positions and sizes
        var positions: [(x: Int, y: Int)] = []
        var thumbnailSizes: [CGSize] = []
        positions.reserveCapacity(actualThumbCount)
        thumbnailSizes.reserveCapacity(actualThumbCount)
        let singleThumbSize = CGSize(width: thumbWidth, height: thumbHeight)

        for i in 0..<actualThumbCount {
            let row = i / cols
            let col = i % cols

            let xPos = CGFloat(col) * (thumbWidth + spacing)
            let yPos = CGFloat(row) * (thumbHeight + spacing)

            positions.append((x: Int(xPos), y: Int(yPos)))
            thumbnailSizes.append(singleThumbSize)
        }

        logger.debug("✅ iPhone layout complete - Size: \(fixedWidth)x\(finalMosaicHeight), Grid: \(actualRows)x\(cols), Thumbs: \(actualThumbCount)")

        return MosaicLayout(
            rows: actualRows,
            cols: cols,
            thumbnailSize: singleThumbSize,
            positions: positions,
            thumbCount: actualThumbCount,
            thumbnailSizes: thumbnailSizes,
            mosaicSize: CGSize(width: fixedWidth, height: finalMosaicHeight)
        )
    }
} 
