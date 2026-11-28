import CoreGraphics

/// The `classic`, `custom` and `auto` grids (I-39, I-40, I-41).
///
/// All three pick their grid by its number of columns, from a cell count that depends only on the
/// columns and the two aspect ratios, never on pixels. So a longer video, a higher density or a
/// wider mosaic can't give fewer thumbnails.
extension LayoutProcessor {
    /// The narrowest thumbnail these layouts draw. A request that doesn't fit gets fewer frames.
    static let minimumThumbnailWidth: CGFloat = 50

    /// The fewest columns holding `count` cells, or, when none does without cells narrower than
    /// ``minimumThumbnailWidth``, the columns holding the most.
    private func columns(holding count: Int, in mosaicWidth: Int, spacing: CGFloat, atLeast minimum: Int,
                         cells: (Int) -> Int) -> Int {
        let widest = Int((CGFloat(mosaicWidth) + spacing) / (Self.minimumThumbnailWidth + spacing))
        var best = (columns: minimum, cells: 0)
        for columns in minimum...max(minimum, widest) {
            let held = cells(columns)
            if held >= count { return columns }
            if held > best.cells { best = (columns, held) }
        }
        return best.columns
    }

    /// A uniform grid of source-aspect cells filling `mosaicWidth`, as close to `aspect` as whole
    /// rows allow.
    func uniformGrid(originalAspectRatio: CGFloat, thumbnailCount: Int, mosaicWidth: Int,
                     aspect: CGFloat) -> MosaicLayout {
        let spacing: CGFloat = 5
        func rows(_ columns: Int) -> Int {
            max(Int((CGFloat(columns) * originalAspectRatio / aspect).rounded()), 1)
        }
        let cols = columns(holding: thumbnailCount, in: mosaicWidth, spacing: spacing, atLeast: 1) { $0 * rows($0) }
        let rowCount = rows(cols)
        let width = (CGFloat(mosaicWidth) - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let height = width / originalAspectRatio
        var positions: [(x: Int, y: Int)] = []
        positions.reserveCapacity(rowCount * cols)
        for row in 0..<rowCount {
            for column in 0..<cols {
                positions.append((x: Int(CGFloat(column) * (width + spacing)), y: Int(CGFloat(row) * (height + spacing))))
            }
        }
        let size = CGSize(width: width, height: height)
        return MosaicLayout(
            rows: rowCount, cols: cols, thumbnailSize: size, positions: positions, thumbCount: positions.count,
            thumbnailSizes: Array(repeating: size, count: positions.count),
            mosaicSize: CGSize(width: CGFloat(mosaicWidth),
                               height: CGFloat(rowCount) * height + spacing * CGFloat(rowCount - 1)))
    }

    /// Three zones: small tiles, a centered band of large ones, small tiles again.
    func calculateCustomLayout(originalAspectRatio: CGFloat, thumbnailCount: Int, mosaicWidth: Int,
                               mosaicAspectRatio: AspectRatio) -> MosaicLayout {
        let spacing: CGFloat = 4
        let aspect = mosaicAspectRatio.ratio
        // How much larger the middle tiles are, by mosaic aspect.
        let ratio: CGFloat = switch aspect {
        case 2.0...: 2.0
        case 1.6...: 1.6
        case 1.33...: 1.33
        default: 1.25
        }
        /// Large and small rows, and large tiles per row, for `columns` small tiles per row.
        func zones(_ columns: Int) -> (smallRows: Int, largeRows: Int, largeColumns: Int) {
            // The canvas height, counted in small rows. The large band takes about a third of it.
            let height = CGFloat(columns) * originalAspectRatio / aspect
            let largeRows = max(Int((height / (3 * ratio)).rounded()), 1)
            let smallRows = max(Int((height - ratio * CGFloat(largeRows)).rounded()), 2)
            return (smallRows, largeRows, max(Int(CGFloat(columns) / ratio + 0.000_001), 1))
        }
        let cols = columns(holding: thumbnailCount, in: mosaicWidth, spacing: spacing, atLeast: 2) {
            let zone = zones($0)
            return zone.smallRows * $0 + zone.largeRows * zone.largeColumns
        }
        let zone = zones(cols)
        let width = (CGFloat(mosaicWidth) - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let small = CGSize(width: width, height: width / originalAspectRatio)
        let large = CGSize(width: width * ratio, height: width * ratio / originalAspectRatio)

        var positions: [(x: Int, y: Int)] = []
        var sizes: [CGSize] = []
        var y: CGFloat = 0
        func addRows(_ count: Int, of size: CGSize, columns: Int, startX: CGFloat) {
            for _ in 0..<count {
                for column in 0..<columns {
                    positions.append((x: Int(startX + CGFloat(column) * (size.width + spacing)), y: Int(y)))
                    sizes.append(size)
                }
                y += size.height + spacing
            }
        }
        let largeRowWidth = large.width * CGFloat(zone.largeColumns) + spacing * CGFloat(zone.largeColumns - 1)
        addRows((zone.smallRows + 1) / 2, of: small, columns: cols, startX: 0)
        addRows(zone.largeRows, of: large, columns: zone.largeColumns,
                startX: max((CGFloat(mosaicWidth) - largeRowWidth) / 2, 0))
        addRows(zone.smallRows / 2, of: small, columns: cols, startX: 0)

        return MosaicLayout(
            rows: zone.smallRows + zone.largeRows, cols: max(cols, zone.largeColumns), thumbnailSize: small,
            positions: positions, thumbCount: positions.count, thumbnailSizes: sizes,
            mosaicSize: CGSize(width: CGFloat(mosaicWidth), height: y - spacing))
    }

    /// A uniform grid in the shape of a screen, at the configured width.
    func calculateAutoLayout(originalAspectRatio: CGFloat, thumbnailCount: Int, mosaicWidth: Int,
                             screenAspect: CGFloat) -> MosaicLayout {
        uniformGrid(originalAspectRatio: originalAspectRatio, thumbnailCount: thumbnailCount,
                    mosaicWidth: mosaicWidth, aspect: screenAspect)
    }
}
