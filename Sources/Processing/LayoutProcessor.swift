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
    private let logger = Logger(subsystem: "com.mosaicKit", category: "layout-processing")
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "layout-processor")
    private let stateLock = NSRecursiveLock()
    private var storedAspectRatio: CGFloat
    public var mosaicAspectRatio: CGFloat {
        get { stateLock.withLock { storedAspectRatio } }
        set { stateLock.withLock { storedAspectRatio = newValue.isFinite && newValue > 0 ? newValue : 16.0 / 9.0 } }
    }
    private var layoutCache: [String: MosaicLayout] = [:]

    /// Whether the one-time `.dynamic` deprecation warning was already logged (I-8, F-7).
    private static let dynamicWarningLogged = Mutex(false)

    /// The layout type that is actually calculated for `layoutType`.
    ///
    /// `.dynamic` is deprecated (I-8): it still decodes, because persisted raw values must
    /// stay valid, but it is laid out as `.custom`. The warning is logged once per process.
    static func resolved(_ layoutType: LayoutType, logger: Logger) -> LayoutType {
        // Compared by raw value so this file doesn't trip the case's own deprecation warning.
        guard layoutType.rawValue == "dynamic" else { return layoutType }
        let firstUse = dynamicWarningLogged.withLock { logged -> Bool in
            defer { logged = true }
            return !logged
        }
        if firstUse {
            logger.warning("LayoutType.dynamic is deprecated and is laid out as .custom; use .custom instead")
        }
        return .custom
    }
    
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
    ///   - thumbnailCount: Number of thumbnails to include
    ///   - mosaicWidth: Desired width of the mosaic
    ///   - density: Density configuration for layout
    ///   - useCustomLayout: Whether to use custom layout algorithm
    /// - Returns: Optimal layout for the mosaic
    public func calculateLayout(
        originalAspectRatio: CGFloat,
        mosaicAspectRatio: AspectRatio,
        thumbnailCount: Int,
        mosaicWidth: Int,
        density: DensityConfig,
        layoutType: LayoutType
    ) -> MosaicLayout {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard originalAspectRatio.isFinite, originalAspectRatio >= 0.01, originalAspectRatio <= 100,
              thumbnailCount > 0, thumbnailCount <= 100_000, mosaicWidth > 0, mosaicWidth <= 16_384 else {
            return MosaicLayout(rows: 0, cols: 0, thumbnailSize: .zero, positions: [], thumbCount: 0,
                                thumbnailSizes: [], mosaicSize: .zero)
        }
        let layoutType = Self.resolved(layoutType, logger: logger)
        storedAspectRatio = mosaicAspectRatio.ratio
        logger.debug("🎯 Starting layout calculation - AR: \(originalAspectRatio), Count: \(thumbnailCount), Width: \(mosaicWidth), target AR: \(self.mosaicAspectRatio)")
        logger.debug("⚙️ Layout mode: \(layoutType.rawValue), Density: \(density.name)")

        let cacheKey = "\(mosaicAspectRatio.rawValue)-\(originalAspectRatio)-\(thumbnailCount)-\(mosaicWidth)-\(density.name)-\(layoutType.rawValue)"
        if layoutType != .auto, let cached = layoutCache[cacheKey] { return cached }

        let layout: MosaicLayout

        switch layoutType {
        case .iphone:
            layout = calculateiPhoneLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth
            )
        case .auto:
            layout = calculateAutoLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount
            )
        case .classic:
            layout = calculateClassicLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth
            )
        default:
            // `.custom`, and the deprecated `.dynamic`, which `resolved(_:logger:)` maps to `.custom`.
            layout = calculateCustomLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth,
                mosaicAspectRatio: mosaicAspectRatio,
                density: density.name
            )
        }

        if layoutCache.count >= 64 { layoutCache.removeAll(keepingCapacity: true) }
        if layoutType != .auto { layoutCache[cacheKey] = layout }
        return layout
    }




    /// Calculate auto layout based on screen size
    private func calculateAutoLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int
    ) -> MosaicLayout {
        logger.debug("🖥️ Calculating auto layout based on screen size")
        
        guard let screenInfo = getLargestScreen() else {
            logger.debug("⚠️ No screen found, falling back to classic layout")
            return calculateClassicLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: 1920
            )
        }
        return calculateAutoLayout(
            originalAspectRatio: originalAspectRatio,
            thumbnailCount: thumbnailCount,
            screenSize: screenInfo.size,
            scale: screenInfo.scale
        )
    }

    /// Auto layout for a screen of `screenSize` points at `scale` pixels per point.
    ///
    /// Everything below is in pixels: the grid is sized for the screen's pixel dimensions, and
    /// the minimum readable thumbnail is 160 points (`160 * scale` pixels). Mixing points and
    /// pixels gave 0 columns on iPhone (390 pt / 480 px) and an empty layout (I-9).
    func calculateAutoLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int,
        screenSize points: CGSize,
        scale scaleFactor: CGFloat
    ) -> MosaicLayout {
        let screenSize = CGSize(width: points.width * scaleFactor, height: points.height * scaleFactor)
        logger.debug("📺 Screen details - Size: \(screenSize.width)x\(screenSize.height) px, Scale: \(scaleFactor)")

        // Calculate minimum readable thumbnail size (scaled for DPI)
        let minThumbWidth: CGFloat = 160 * scaleFactor
        let minThumbHeight = minThumbWidth / originalAspectRatio
        logger.debug("min thumb width: \(minThumbWidth), min thumb height: \(minThumbHeight)")
        // Calculate maximum possible thumbnails (at least one cell per axis)
        let maxHorizontal = max(Int(floor(screenSize.width / minThumbWidth)), 1)
        let maxVertical = max(Int(floor(screenSize.height / minThumbHeight)), 1)
        logger.debug("max horizontal: \(maxHorizontal), max vertical: \(maxVertical)")
        var bestLayout: MosaicLayout?
        var bestScore: CGFloat = 0
        
        // Try different grid configurations
        for rows in 1...maxVertical {
            for cols in 1...maxHorizontal {
                let totalThumbs = rows * cols
                if totalThumbs < thumbnailCount {
                    continue
                }
                
                let thumbWidth = screenSize.width / CGFloat(cols)
                let thumbHeight = screenSize.height / CGFloat(rows)
                
                // Calculate scores
                let coverage = (thumbWidth * CGFloat(cols) * thumbHeight * CGFloat(rows)) / (screenSize.width * screenSize.height)
                let readabilityScore = (thumbWidth * thumbHeight) / (minThumbWidth * minThumbHeight)
                let score = coverage * 0.6 + readabilityScore * 0.4
                
                if score > bestScore {
                    bestScore = score
                    
                    // Generate positions and sizes with spacing
                    var positions: [(x: Int, y: Int)] = []
                    var thumbnailSizes: [CGSize] = []
                    positions.reserveCapacity(thumbnailCount)
                    thumbnailSizes.reserveCapacity(thumbnailCount)
                    let spacing: CGFloat = 5 // 5-pixel spacing for visual separation
                    
                    // Adjust thumbnail size to account for spacing
                    let adjustedThumbWidth = thumbWidth - spacing
                    let adjustedThumbHeight = thumbHeight - spacing
                    
                    for row in 0..<rows {
                        for col in 0..<cols {
                            if positions.count < thumbnailCount {
                                positions.append((
                                    // Include spacing between thumbnails
                                    x: Int(CGFloat(col) * (adjustedThumbWidth + spacing)),
                                    y: Int(CGFloat(row) * (adjustedThumbHeight + spacing))
                                ))
                                thumbnailSizes.append(CGSize(
                                    width: adjustedThumbWidth,
                                    height: adjustedThumbHeight
                                ))
                            }
                        }
                    }
                    
                    bestLayout = MosaicLayout(
                        rows: rows,
                        cols: cols,
                        thumbnailSize: CGSize(width: adjustedThumbWidth, height: adjustedThumbHeight),
                        positions: positions,
                        thumbCount: thumbnailCount,
                        thumbnailSizes: thumbnailSizes,
                        mosaicSize: screenSize
                    )
                }
            }
        }
        
        logger.debug("✅ Auto layout complete")
        logger.debug("\(bestLayout?.description() ?? "No layout found")")
        return bestLayout ?? calculateClassicLayout(
            originalAspectRatio: originalAspectRatio,
            thumbnailCount: thumbnailCount,
            mosaicWidth: Int(screenSize.width)
        )
    }

    private func calculateCustomLayout(
    originalAspectRatio: CGFloat,
    thumbnailCount: Int,
    mosaicWidth: Int,
    mosaicAspectRatio: AspectRatio,
    density: String
) -> MosaicLayout {
    
    let targetCountRange = Int(Double(thumbnailCount) * 0.5)...Int(Double(thumbnailCount) * 2.5)
    let mosaicWidthF = CGFloat(mosaicWidth)
    let mosaicHeightF = mosaicWidthF / mosaicAspectRatio.ratio
    let zoneHeight = mosaicHeightF / 3.0

    // Padding between thumbnails
    let horizontalPadding: CGFloat = 4.0
    let verticalPadding: CGFloat = 4.0

    // Ratio between large and small thumbs based on mosaic A/R
    func sizeRatio(for aspect: CGFloat) -> CGFloat {
        switch aspect {
        case let a where a >= 2.0: return 2.0
        case let a where a >= 1.6: return 1.6
        case let a where a >= 1.33: return 1.33
        default: return 1.25
        }
    }

    let sizeRatio = sizeRatio(for: mosaicAspectRatio.ratio)

    var bestLayout: MosaicLayout?
    var bestThumbDiff: Int = Int.max
    let maxSmallRows = max(8, Int(thumbnailCount/10))
    for smallRows in 1...maxSmallRows {
        let smallThumbHeight = (zoneHeight - verticalPadding * CGFloat(smallRows - 1)) / CGFloat(smallRows)
        let largeThumbHeight = smallThumbHeight * sizeRatio

        let midRows = Int((zoneHeight - verticalPadding * CGFloat(smallRows - 1)) / largeThumbHeight)
        // Compute how many thumbs fit per row, adjusting for padding
        let smallThumbWidth = smallThumbHeight * originalAspectRatio
        let maxSmallCols = Int((mosaicWidthF + horizontalPadding) / (smallThumbWidth + horizontalPadding))
        let exactSmallThumbWidth = (mosaicWidthF - (CGFloat(maxSmallCols - 1) * horizontalPadding)) / CGFloat(maxSmallCols)
        let exactSmallThumbHeight = exactSmallThumbWidth / originalAspectRatio
        let largeThumbWidth = exactSmallThumbWidth * sizeRatio
        let exactLargeThumbHeight = largeThumbWidth / originalAspectRatio
        let maxLargeCols = Int((mosaicWidthF + horizontalPadding) / (largeThumbWidth + horizontalPadding))
        // Total thumbnails
        let smallThumbCount = maxSmallCols * smallRows * 2
        let largeThumbCount = maxLargeCols * midRows
        let totalCount = smallThumbCount + largeThumbCount
        if !targetCountRange.contains(totalCount) { continue }
        var positions: [Position] = []
        var sizes: [CGSize] = []
        positions.reserveCapacity(totalCount)
        sizes.reserveCapacity(totalCount)

        var yCursor: CGFloat = 0

        // Top small rows
        for _ in 0..<smallRows {
            for col in 0..<maxSmallCols {
                let x = CGFloat(col) * (exactSmallThumbWidth + horizontalPadding)
                positions.append(Position(x: Int(x), y: Int(yCursor)))
                sizes.append(CGSize(width: exactSmallThumbWidth, height: exactSmallThumbHeight))
            }
            yCursor += exactSmallThumbHeight + verticalPadding
        }

        // Middle large rows
        for _ in 0..<midRows {
            // Calculate total width of large thumbnails in this row
            let totalLargeWidth = largeThumbWidth * CGFloat(maxLargeCols)
            // Calculate starting x position to center the row
            let startX = (mosaicWidthF - totalLargeWidth - (CGFloat(maxLargeCols - 1) * horizontalPadding)) / 2
            var currentX = startX
            
            for _ in 0..<maxLargeCols {
                positions.append(Position(x: Int(currentX), y: Int(yCursor)))
                sizes.append(CGSize(width: largeThumbWidth, height: exactLargeThumbHeight))
                currentX += largeThumbWidth + horizontalPadding
            }
            yCursor += exactLargeThumbHeight + verticalPadding
        }

        // Bottom small rows
        for _ in 0..<smallRows {
            for col in 0..<maxSmallCols {
                let x = CGFloat(col) * (exactSmallThumbWidth + horizontalPadding)
                    positions.append(Position(x: Int(x), y: Int(yCursor)))
                sizes.append(CGSize(width: exactSmallThumbWidth, height: exactSmallThumbHeight))
            }
            yCursor += exactSmallThumbHeight + verticalPadding
        }

        let thumbDiff = abs(totalCount - thumbnailCount)
        if thumbDiff < bestThumbDiff {
            bestThumbDiff = thumbDiff

            bestLayout = MosaicLayout(
                rows: smallRows * 2 + midRows,
                cols: max(maxSmallCols, maxLargeCols),
                thumbnailSize: CGSize(width: exactSmallThumbWidth, height: exactSmallThumbHeight),
                positions: positions.map {(x: $0.x, y: $0.y) },
                thumbCount: totalCount,
                thumbnailSizes: sizes,
                mosaicSize: CGSize(width: CGFloat(Int(mosaicWidthF)), height: CGFloat(Int(yCursor - verticalPadding)))
            )
        }
    }
    if (bestLayout == nil)
    {
        logger.debug("Staring another round")
        let newThumbCount = Int(Double(thumbnailCount) * 0.8)
        if newThumbCount <= 4
        {
            return calculateClassicLayout(originalAspectRatio: originalAspectRatio, thumbnailCount: 4, mosaicWidth: mosaicWidth)
        }
        return calculateCustomLayout(originalAspectRatio: originalAspectRatio, thumbnailCount: newThumbCount, mosaicWidth: mosaicWidth, mosaicAspectRatio: mosaicAspectRatio, density:density)
    }
    return bestLayout!
}
    private func calculateClassicLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int,
        mosaicWidth: Int
    ) -> MosaicLayout {
        logger.debug("📊 Calculating classic layout")
        
        let mosaicHeight = Int(CGFloat(mosaicWidth) / mosaicAspectRatio)
        
        let count = thumbnailCount
        
        func calculateLayout(rows: Int) -> MosaicLayout? {
            // Add spacing between thumbnails
            let spacing: CGFloat = 5 // 5-pixel spacing for visual separation
            var thumbnailSizes: [CGSize] = []
            let cols = Int(ceil(Double(count) / Double(rows)))
            // Adjust width calculation to account for spacing
            let availableWidth = CGFloat(mosaicWidth) - (spacing * CGFloat(cols - 1))
            let thumbnailWidth = availableWidth / CGFloat(cols)
            let thumbnailHeight = thumbnailWidth / originalAspectRatio
            let adjustedRows = min(rows, Int(ceil((CGFloat(mosaicHeight) + spacing * CGFloat(rows - 1)) / thumbnailHeight)))
            if (adjustedRows < 0 || availableWidth < 0 || thumbnailWidth < 0 || thumbnailHeight < 0)
            {
                return nil
            }
            var positions: [(x: Int, y: Int)] = []
            positions.reserveCapacity(adjustedRows * cols)
            thumbnailSizes.reserveCapacity(adjustedRows * cols)
            var y: CGFloat = 0

            for row in 0..<adjustedRows {
                var x: CGFloat = 0
                for col in 0..<cols {
                    if positions.count <= Int(Double(count) * 1.20) {
                        positions.append((x: Int(x), y: Int(y)))
                        thumbnailSizes.append(CGSize(width: thumbnailWidth, height: thumbnailHeight))
                        // Add spacing after each thumbnail except the last one in a row
                        x += thumbnailWidth + (col < cols - 1 ? spacing : 0)
                    }
                }
                // Add spacing after each row except the last one
                y += thumbnailHeight + (row < adjustedRows - 1 ? spacing : 0)
            }
            
            // Calculate total width and height including spacing
            let totalWidth = (thumbnailWidth * CGFloat(cols)) + (spacing * CGFloat(cols - 1))
            let totalHeight = (thumbnailHeight * CGFloat(adjustedRows)) + (spacing * CGFloat(adjustedRows - 1))
            
            return MosaicLayout(
                rows: adjustedRows,
                cols: cols,
                thumbnailSize: CGSize(width: thumbnailWidth, height: thumbnailHeight),
                positions: positions,
                thumbCount: positions.count,
                thumbnailSizes: thumbnailSizes,
                mosaicSize: CGSize(
                    width: totalWidth,
                    height: totalHeight
                )
            )
        }
        
        // Find optimal layout
        var bestLayout = calculateLayout(rows: Int(sqrt(Double(thumbnailCount))))
        var bestScore = Double.infinity
        
        for rows in 1...thumbnailCount {
            if let layout = calculateLayout(rows: rows) {
                let fillRatio = (CGFloat(layout.rows) * layout.thumbnailSize.height) / CGFloat(mosaicHeight)
                let thumbnailCount = layout.positions.count
                let countDifference = abs(thumbnailCount - count)
                let score = (1 - fillRatio) + Double(countDifference) / Double(count)
                
                if score < bestScore && score > 0{
                    bestScore = score
                    bestLayout = layout
                }
                
                if CGFloat(layout.rows) * layout.thumbnailSize.height > CGFloat(mosaicHeight) {
                    break
                }
            }else
                {
                break
            }
        }
        
        logger.debug("✅ Classic layout complete - Score: \(bestScore)")
        return bestLayout!
    }
    
    // MARK: - Helper Methods

    /// Calculate thumbnail count based on video duration and width
    /// - Parameters:
    ///   - duration: Video duration in seconds
    ///   - width: Mosaic width
    ///   - density: Density configuration
    /// - Returns: Optimal number of thumbnails
    public func calculateThumbnailCount(
        duration: Double,
        width: Int,
        density: DensityConfig,
        layoutType: LayoutType = .custom,
        videoAR: Double
    ) -> Int {
        logger.debug("🔢 Calculating thumbnail count - Duration: \(duration)s, Width: \(width)")
        
        guard duration.isFinite, duration > 0, width > 0, width <= 16_384, videoAR.isFinite, videoAR >= 0.01, videoAR <= 100 else { return 0 }
        if duration < 5 { return 4 }
        
        if layoutType == .auto {
            guard let screenInfo = getLargestScreen() else {
                logger.debug("⚠️ No screen found, using minimum count: 4")
                return 4
            }
            let maxCount = max(min(calculateMaxThumbnails(screenSize: screenInfo.size, scale: screenInfo.scale, videoAR: videoAR), 800), 4)
            logger.debug("🖥️ Auto layout max thumbnails: \(maxCount)")
            return maxCount
        } else {
            let base = Double(width) / 200.0
            let k = 10.0
            let rawCount = base + k * log(duration)
            let totalCount = Int(min(max(rawCount * density.factor, 4), 800))
            logger.debug("📊 Calculated count: \(totalCount) (raw: \(rawCount))")
            return totalCount
        }
    
    }
    
    /// How many 160-point-wide thumbnails of aspect ratio `videoAR` fit on a screen of
    /// `screenSize` points at `scale` pixels per point. Measured in pixels on both sides (I-9).
    func calculateMaxThumbnails(screenSize: CGSize, scale: CGFloat, videoAR: Double) -> Int {
        let minThumbWidth: CGFloat = 160 * scale
        let maxHorizontal = max(Int(floor(screenSize.width * scale / minThumbWidth)), 1)
        let maxVertical = max(Int(floor(screenSize.height * scale / (minThumbWidth / videoAR))), 1)
        return maxHorizontal * maxVertical
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
