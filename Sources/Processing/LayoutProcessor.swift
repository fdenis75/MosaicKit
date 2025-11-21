import Foundation
import CoreGraphics
import OSLog
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Handles mosaic layout calculations and optimization
@available(macOS 15, iOS 18, *)
public final class LayoutProcessor {
    private let logger = Logger(subsystem: "com.mosaicKit", category: "layout-processing")
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "layout-processor")
    public var mosaicAspectRatio: CGFloat
    private var layoutCache: [String: MosaicLayout] = [:]
    
    /// Get the screen size for the main screen
    private func getMainScreenSize() -> (size: CGSize, scale: CGFloat)? {
        let state = signposter.beginInterval("Get Main Screen Size")
        defer { signposter.endInterval("Get Main Screen Size", state) }
        
        #if canImport(AppKit)
        guard let mainScreen = NSScreen.main else { return nil }
        return (mainScreen.visibleFrame.size, mainScreen.backingScaleFactor)
        #elseif canImport(UIKit)
        let mainScreen = UIScreen.main
        return (mainScreen.bounds.size, mainScreen.scale)
        #else
        return nil
        #endif
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
        
        self.mosaicAspectRatio = aspectRatio
    }
    
    /// Update the mosaic aspect ratio
    /// - Parameter ratio: New aspect ratio to use
    public func updateAspectRatio(_ ratio: CGFloat) {
        let state = signposter.beginInterval("Update Aspect Ratio")
        defer { signposter.endInterval("Update Aspect Ratio", state) }
        
        self.mosaicAspectRatio = ratio
        layoutCache.removeAll()
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
        useCustomLayout: Bool,
        useAutoLayout: Bool = false,
    useDynamicLayout: Bool = false,
        forIphone: Bool = false
    ) -> MosaicLayout {
        logger.debug("🎯 Starting layout calculation - AR: \(originalAspectRatio), Count: \(thumbnailCount), Width: \(mosaicWidth), target AR: \(self.mosaicAspectRatio)")
        //     logger.debug("⚙️ Layout mode - Auto: \(useAutoLayout), Custom: \(useCustomLayout), Dynamic: \(useDynamicLayout), Density: \(density.name)")
        
        let layout =
        if forIphone {
            calculateiPhoneLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth
            )
        
    }else if useAutoLayout {
            calculateAutoLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount
            )
        } else if useCustomLayout {
            calculateCustomLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth,
                mosaicAspectRatio: mosaicAspectRatio,
                density: density.name
            )
        } else if useDynamicLayout {
            calculateDynamicLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth,
                density: density
            )
        } else {
            calculateClassicLayout(
                originalAspectRatio: originalAspectRatio,
                thumbnailCount: thumbnailCount,
                mosaicWidth: mosaicWidth
            )
        }
        
 //       logger.debug("✅ Layout calculated - Size: \(layout.mosaicSize.width)x\(layout.mosaicSize.height), Grid: \(layout.rows)x\(layout.cols)")
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
        
        let screenSize = screenInfo.size
        let scaleFactor = screenInfo.scale
        logger.debug("📺 Screen details - Size: \(screenSize.width)x\(screenSize.height), Scale: \(scaleFactor)")
        
        // Calculate minimum readable thumbnail size (scaled for DPI)
        let minThumbWidth: CGFloat = 160 * scaleFactor
        let minThumbHeight = minThumbWidth / originalAspectRatio
        
        // Calculate maximum possible thumbnails
        let maxHorizontal = Int(floor(screenSize.width / minThumbWidth))
        let maxVertical = Int(floor(screenSize.height / minThumbHeight))
        
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
        return bestLayout ?? calculateClassicLayout(
            originalAspectRatio: originalAspectRatio,
            thumbnailCount: thumbnailCount,
            mosaicWidth: Int(screenSize.width)
        )
    }
    /*
    private func calculateCustomLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int,
        mosaicWidth: Int,
        mosaicAspectRatio: AspectRatio,
        density: String
    ) -> MosaicLayout {
        let state = signposter.beginInterval("Calculate Custom Layout")
        defer { signposter.endInterval("Calculate Custom Layout", state) }
        
        logger.debug("🎨 Calculating custom layout - Count: \(thumbnailCount)")
        
        // Calculate initial mosaic height to match target aspect ratio
        let targetAspectRatio = mosaicAspectRatio.ratio
        let mosaicHeight = Int(CGFloat(mosaicWidth) / targetAspectRatio)
        
        // Calculate optimal grid dimensions
        func calculateGrid() -> (smallRows: Int, largeRows: Int, smallCols: Int, largeCols: Int) {
            // Base calculation on target aspect ratio and thumbnail count
            let isPortrait = originalAspectRatio < 1.0
            let targetGridAspectRatio = targetAspectRatio * (isPortrait ? 0.8 : 1.2) // Adjust for video orientation
            
            // Calculate initial grid size
            let totalArea = Double(thumbnailCount)
            let idealCols = Int(sqrt(totalArea * Double(targetGridAspectRatio)))
            let idealRows = Int(ceil(Double(thumbnailCount) / Double(idealCols)))
            
            // Adjust for video aspect ratio
            let baseSmallCols = min(max(4, idealCols), isPortrait ? 12 : 8)
            
            // Determine rows distribution (1/3 for large thumbnails)
            let totalRows = idealRows
            let largeRows = max(1, totalRows / 3)
            let smallRows = totalRows - largeRows
            
            // Calculate columns for large thumbnails
            let largeCols = max(2, baseSmallCols / 2)
            
            return (smallRows, largeRows, baseSmallCols, largeCols)
        }
        
        let (smallRows, largeRows, smallCols, largeCols) = calculateGrid()
        
        // Calculate thumbnail sizes
        let smallThumbWidth = CGFloat(mosaicWidth) / CGFloat(smallCols)
        let smallThumbHeight = smallThumbWidth / originalAspectRatio
        let largeThumbWidth = smallThumbWidth * 2
        let largeThumbHeight = largeThumbWidth / originalAspectRatio
        
        // Generate positions with small thumbnails at top and bottom
        var positions: [(x: Int, y: Int)] = []
        var thumbnailSizes: [CGSize] = []
        var currentY: CGFloat = 0
        var remainingThumbnails = thumbnailCount
        
        // Helper function to add a row of thumbnails
        func addRow(isSmall: Bool) -> Int {
            let cols = isSmall ? smallCols : largeCols
            let thumbWidth = isSmall ? smallThumbWidth : largeThumbWidth
            let thumbHeight = isSmall ? smallThumbHeight : largeThumbHeight
            var currentX: CGFloat = 0
            var addedCount = 0
            
            // Calculate spacing to center thumbnails in row
            let totalWidth = thumbWidth * CGFloat(min(cols, remainingThumbnails))
            let startX = (CGFloat(mosaicWidth) - totalWidth) / 2
            currentX = startX
            
            for _ in 0..<cols {
                if remainingThumbnails > 0 {
                    positions.append((x: Int(currentX), y: Int(currentY)))
                    thumbnailSizes.append(CGSize(width: thumbWidth, height: thumbHeight))
                    currentX += thumbWidth
                    remainingThumbnails -= 1
                    addedCount += 1
                }
            }
            currentY += thumbHeight
            return addedCount
        }
        
        // Add top small rows
        let topSmallRows = smallRows / 2
        for _ in 0..<topSmallRows {
            _ = addRow(isSmall: true)
        }
        
        // Add middle large rows
        for _ in 0..<largeRows {
            _ = addRow(isSmall: false)
        }
        
        // Add remaining small rows
        let bottomSmallRows = smallRows - topSmallRows
        for _ in 0..<bottomSmallRows {
            _ = addRow(isSmall: true)
        }
        
        // Calculate final dimensions
        let finalHeight = Int(currentY)
        
        return MosaicLayout(
            rows: smallRows + largeRows,
            cols: max(smallCols, largeCols),
            thumbnailSize: CGSize(width: smallThumbWidth, height: smallThumbHeight),
            positions: positions,
            thumbCount: thumbnailCount,
            thumbnailSizes: thumbnailSizes,
            mosaicSize: CGSize(width: mosaicWidth, height: finalHeight)
        )
    }
    */
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
    var maxSmallRows = max(8, Int(thumbnailCount/10))
   // print("maxsmallRows: \(maxSmallRows)")
    for smallRows in 1...maxSmallRows {
     //   print("smallRows: \(smallRows)")
        let smallThumbHeight = (zoneHeight - verticalPadding * CGFloat(smallRows - 1)) / CGFloat(smallRows)
        let largeThumbHeight = smallThumbHeight * sizeRatio

        let midRows = Int((zoneHeight - verticalPadding * CGFloat(smallRows - 1)) / largeThumbHeight)
   //     print("midRows: \(midRows)")
        let actualHeight =
            CGFloat(smallRows * 2) * smallThumbHeight +
            CGFloat(midRows) * largeThumbHeight +
            verticalPadding * CGFloat(smallRows * 2 + midRows - 1)

        // Compute how many thumbs fit per row, adjusting for padding
        let smallThumbWidth = smallThumbHeight * originalAspectRatio
//        print("smallThumbWidth: \(smallThumbWidth)")
        let maxSmallCols = Int((mosaicWidthF + horizontalPadding) / (smallThumbWidth + horizontalPadding))
  //      print("maxSmallCols: \(maxSmallCols)")
        let exactSmallThumbWidth = (mosaicWidthF - (CGFloat(maxSmallCols - 1) * horizontalPadding)) / CGFloat(maxSmallCols)
    //    print("exactSmallThumbWidth: \(exactSmallThumbWidth)")
        let exactSmallThumbHeight = exactSmallThumbWidth / originalAspectRatio
      //  print("exactSmallThumbHeight: \(exactSmallThumbHeight)")
        let largeThumbWidth = exactSmallThumbWidth * sizeRatio
        //    print("largeThumbWidth: \(largeThumbWidth)")
        let exactLargeThumbHeight = largeThumbWidth / originalAspectRatio
   //     print("exactLargeThumbHeight: \(exactLargeThumbHeight)")
        let maxLargeCols = Int((mosaicWidthF + horizontalPadding) / (largeThumbWidth + horizontalPadding))
     //   print("maxLargeCols: \(maxLargeCols)")
        // Total thumbnails
        let smallThumbCount = maxSmallCols * smallRows * 2
      //  print("smallThumbCount: \(smallThumbCount)")
        let largeThumbCount = maxLargeCols * midRows
     //   print("largeThumbCount: \(largeThumbCount)")
        let totalCount = smallThumbCount + largeThumbCount
        //  print("totalCount: \(totalCount)")
        if !targetCountRange.contains(totalCount) { continue }
       // print("totalCount is in target range")
        var positions: [Position] = []
        var sizes: [CGSize] = []

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
            
            for col in 0..<maxLargeCols {
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
   //     print("thumbDiff: \(thumbDiff)")
        if thumbDiff < bestThumbDiff {
     //       print("thumbDiff is less than bestThumbDiff")
            bestThumbDiff = thumbDiff
            //     print("bestThumbDiff: \(bestThumbDiff)")
            
            bestLayout = MosaicLayout(
                rows: smallRows * 2 + midRows,
                cols: max(maxSmallCols, maxLargeCols),
                thumbnailSize: CGSize(width: exactSmallThumbWidth, height: exactSmallThumbHeight),
                positions: positions.map {(x: $0.x, y: $0.y) },
                thumbCount: totalCount,
                thumbnailSizes: sizes,
                mosaicSize: CGSize(width: CGFloat(Int(mosaicWidthF)), height: CGFloat(Int(yCursor - verticalPadding)))
            )
       //     print("bestLayout: \(bestLayout)")
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
        var thumbnailSizes: [CGSize] = []
        let count = thumbnailCount
        
        func calculateLayout(rows: Int) -> MosaicLayout {
            // Add spacing between thumbnails
            let spacing: CGFloat = 5 // 5-pixel spacing for visual separation
            
            let cols = Int(ceil(Double(count) / Double(rows)))
            // Adjust width calculation to account for spacing
            let availableWidth = CGFloat(mosaicWidth) - (spacing * CGFloat(cols - 1))
            let thumbnailWidth = availableWidth / CGFloat(cols)
            let thumbnailHeight = thumbnailWidth / originalAspectRatio
            let adjustedRows = min(rows, Int(ceil((CGFloat(mosaicHeight) + spacing * CGFloat(rows - 1)) / thumbnailHeight)))
            
            var positions: [(x: Int, y: Int)] = []
            var y: CGFloat = 0
            
            for row in 0..<adjustedRows {
                var x: CGFloat = 0
                for col in 0..<cols {
                    if positions.count < count {
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
                thumbCount: count,
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
            let layout = calculateLayout(rows: rows)
            let fillRatio = (CGFloat(layout.rows) * layout.thumbnailSize.height) / CGFloat(mosaicHeight)
            let thumbnailCount = layout.positions.count
            let countDifference = abs(thumbnailCount - count)
            let score = (1 - fillRatio) + Double(countDifference) / Double(count)
            
            if score < bestScore {
                bestScore = score
                bestLayout = layout
            }
            
            if CGFloat(layout.rows) * layout.thumbnailSize.height > CGFloat(mosaicHeight) {
                break
            }
        }
        
        logger.debug("✅ Classic layout complete - Score: \(bestScore)")
        return bestLayout
    }
    
    private func calculateDynamicLayout(
        originalAspectRatio: CGFloat,
        thumbnailCount: Int,
        mosaicWidth: Int,
        density: DensityConfig
    ) -> MosaicLayout {
        let state = signposter.beginInterval("Calculate Dynamic Layout")
        defer { signposter.endInterval("Calculate Dynamic Layout", state) }
        
        logger.debug("🎨 Calculating dynamic layout with center emphasis")
        
        // Calculate base dimensions
        let mosaicHeight = Int(CGFloat(mosaicWidth) / mosaicAspectRatio)
        let baseSpacing: CGFloat = 4
        
        // Calculate grid dimensions based on thumbnail count
        let gridSize = calculateOptimalGridSize(for: thumbnailCount)
        let (rows, cols) = gridSize
        
        // Calculate center point
        let centerRow = rows / 2
        let centerCol = cols / 2
        
        // Calculate maximum thumbnail size (center)
        let maxThumbWidth = CGFloat(mosaicWidth) / CGFloat(cols) * 1.5
        let maxThumbHeight = maxThumbWidth / originalAspectRatio
        
        // Calculate minimum thumbnail size (edges)
        let minThumbWidth = CGFloat(mosaicWidth) / CGFloat(cols) * 0.8
        let minThumbHeight = minThumbWidth / originalAspectRatio
        
        // Generate positions and sizes with dynamic scaling
        var positions: [(x: Int, y: Int)] = []
        var thumbnailSizes: [CGSize] = []
        var currentY: CGFloat = 0
        var currentX: CGFloat = 0
        for row in 0..<rows {
            currentX = 0
            let rowHeight = calculateRowHeight(
                row: row,
                centerRow: centerRow,
                minHeight: minThumbHeight,
                maxHeight: maxThumbHeight
            )
            
            for col in 0..<cols {
                if positions.count < thumbnailCount {
                    let thumbWidth = calculateThumbWidth(
                        col: col,
                        centerCol: centerCol,
                        minWidth: minThumbWidth,
                        maxWidth: maxThumbWidth
                    )
                    let thumbHeight = thumbWidth / originalAspectRatio
                    
                    positions.append((x: Int(currentX), y: Int(currentY)))
                    thumbnailSizes.append(CGSize(width: thumbWidth, height: thumbHeight))
                    
                    currentX += thumbWidth + baseSpacing
                }
            }
            
            currentY += rowHeight + baseSpacing
        }
        
        // Calculate final mosaic dimensions
        let finalWidth = Int(currentX)
        let finalHeight = Int(currentY)
        
        return MosaicLayout(
            rows: rows,
            cols: cols,
            thumbnailSize: CGSize(width: minThumbWidth, height: minThumbHeight),
            positions: positions,
            thumbCount: thumbnailCount,
            thumbnailSizes: thumbnailSizes,
            mosaicSize: CGSize(width: finalWidth, height: finalHeight)
        )
    }
    
    private func calculateOptimalGridSize(for thumbnailCount: Int) -> (rows: Int, cols: Int) {
        // Calculate base grid size
        let baseSize = Int(sqrt(Double(thumbnailCount)))
        let rows = baseSize
        let cols = Int(ceil(Double(thumbnailCount) / Double(rows)))
        
        // Adjust for better visual balance
        let aspectRatio = CGFloat(cols) / CGFloat(rows)
        if aspectRatio > 2.0 {
            return (rows: rows + 1, cols: cols - 1)
        } else if aspectRatio < 0.5 {
            return (rows: rows - 1, cols: cols + 1)
        }
        
        return (rows: rows, cols: cols)
    }
    
    private func calculateRowHeight(
        row: Int,
        centerRow: Int,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        let distanceFromCenter = abs(row - centerRow)
        let scale = 1.0 - (CGFloat(distanceFromCenter) * 0.15)
        return minHeight + (maxHeight - minHeight) * scale
    }
    
    private func calculateThumbWidth(
        col: Int,
        centerCol: Int,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        let distanceFromCenter = abs(col - centerCol)
        let scale = 1.0 - (CGFloat(distanceFromCenter) * 0.15)
        return minWidth + (maxWidth - minWidth) * scale
    }
    
    // MARK: - Helper Methods
    /*
    private func getInitialLayoutParams(_ density: String, aspectRatio: AspectRatio) -> (largeCols: Int, largeRows: Int, smallCols: Int, smallRows: Int) {
        switch density.uppercased() {           
        case "XXL":
            switch aspectRatio {
            case .widescreen:
                return (2, 1, 4, 2)
            case .standard:
                return (3, 1, 6, 2)
            case .square:
                return (4, 1, 8, 2)
            case .ultrawide:
                return (5, 1, 10, 2)
        case "XL":
            return (3, 1, 6, 2)
        case "L":
            return (3, 2, 6, 4)
        case "M":
            return (4, 2, 8, 4)
        case "S":
            return (6, 2, 12, 4)
        case "XS":
            return (8, 2, 16, 4)
        case "XXS":
            return (9, 4, 18, 8)
        default:
            return (4, 2, 8, 4)
        }
    }
    
    private func generateRowConfigs(
        largeCols: Int,
        largeRows: Int,
        smallCols: Int,
        smallRows: Int
    ) -> [(smallCount: Int, largeCount: Int)] {
        var configs: [(Int, Int)] = []
        let halfSmallRows = smallRows / 2
        
        // Add top small rows
        for _ in 0..<halfSmallRows {
            configs.append((smallCols, 0))
        }
        
        // Add large rows
        for _ in 0..<largeRows {
            configs.append((0, largeCols))
        }
        
        // Add bottom small rows
        for _ in 0..<halfSmallRows {
            configs.append((smallCols, 0))
        }
        
        return configs
    }
    */
    private func adjustPortraitLayout(
        smallCols: Int,
        largeCols: Int,
        smallRows: Int,
        largeRows: Int,
        smallThumbWidth: CGFloat,
        smallThumbHeight: CGFloat,
        mosaicAspectRatio: CGFloat
    ) -> (smallCols: Int, largeCols: Int) {
        var adjustedSmallCols = smallCols
        var adjustedLargeCols = largeCols
        
        var mozW = smallThumbWidth * CGFloat(adjustedSmallCols)
        var mozH = smallThumbHeight * CGFloat(smallRows + largeRows * 2)
        var mozAR = mozW / mozH
        
        while mozAR < mosaicAspectRatio {
            adjustedSmallCols += 2
            adjustedLargeCols += 1
            mozW = smallThumbWidth * CGFloat(adjustedSmallCols)
            mozH = smallThumbHeight * CGFloat(smallRows + largeRows * 2)
            mozAR = mozW / mozH
        }
        
        return (adjustedSmallCols, adjustedLargeCols)
    }
    
    private func adjustLandscapeLayout(
        smallRows: Int,
        largeRows: Int,
        mosaicHeight: Int,
        smallThumbHeight: CGFloat
    ) -> (smallRows: Int, largeRows: Int) {
        var adjustedSmallRows = smallRows
        var adjustedLargeRows = largeRows
        
        let tmpTotalRows = Int(CGFloat(mosaicHeight) / smallThumbHeight)
        var diff = tmpTotalRows - (adjustedSmallRows + 2 * adjustedLargeRows)
        
        while diff > 0 {
            if diff >= 2 {
                adjustedLargeRows += 1
                diff -= 2
            } else if diff >= 1 {
                adjustedSmallRows += 1
                diff -= 1
            }
        }
        
        return (adjustedSmallRows, adjustedLargeRows)
    }
    
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
        useAutoLayout: Bool = false
    ) -> Int {
        logger.debug("🔢 Calculating thumbnail count - Duration: \(duration)s, Width: \(width)")
        
        if duration < 5 { return 4 }
        
        if useAutoLayout {
            guard let screenInfo = getLargestScreen() else {
                logger.debug("⚠️ No screen found, using minimum count: 4")
                return 4
            }
            let maxCount = min(calculateMaxThumbnails(screenSize: screenInfo.size, scale: screenInfo.scale), 800)
            logger.debug("🖥️ Auto layout max thumbnails: \(maxCount)")
            return maxCount
        } else {
            let base = Double(width) / 200.0
            let k = 10.0
            let rawCount = base + k * log(duration)
            let totalCount = min(Int(rawCount * density.factor), 800)
            logger.debug("📊 Calculated count: \(totalCount) (raw: \(rawCount))")
            return totalCount
        }
    
    }
    
    private func calculateMaxThumbnails(screenSize: CGSize, scale: CGFloat) -> Int {
        let minThumbWidth: CGFloat = 160 * scale
        let maxHorizontal = Int(floor(screenSize.width / minThumbWidth))
        let maxVertical = Int(floor(screenSize.height / (minThumbWidth / mosaicAspectRatio)))
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
