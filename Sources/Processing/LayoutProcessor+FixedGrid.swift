import Foundation
import CoreGraphics

extension LayoutProcessor {

    /// The gutter between cells. It is the same fixed baseline the renderer subtracts from every
    /// cell; extra `spacing` above it is applied as an inset (see ``planFixedGrid(_:sourceAspectRatio:mosaicAspectRatio:mosaicWidth:spacing:reservedHeight:)``).
    static let fixedGridGutter = 4

    /// The largest texture side the Metal pipeline accepts.
    static let maximumCanvasSide = 16_384

    /// Computes a fixed-grid layout without touching any video: pure, deterministic, and cheap
    /// enough for a live preview. Never throws: a request that cannot be laid out comes back as
    /// ``FixedGridPlan/infeasible(_:suggestions:)`` with the reason.
    ///
    /// With ``GridFitMode/adaptCanvas`` (the only mode available so far) the canvas height follows
    /// the grid: every cell gets the source aspect ratio, so no frame is distorted, cropped or
    /// letterboxed. The requested width is a **maximum**: the canvas is trimmed to whole cells
    /// (less than `columns` pixels) and shrunk when the grid would exceed the texture height limit.
    ///
    /// - Parameters:
    ///   - grid: The rows, columns and fit mode.
    ///   - sourceAspectRatio: The display aspect ratio of the video (`VideoInput.width / height`).
    ///   - mosaicAspectRatio: The mosaic's aspect preset. Not used to shape the canvas by `.adaptCanvas`.
    ///   - mosaicWidth: The maximum canvas width in pixels.
    ///   - spacing: `LayoutConfiguration.spacing`. The gutter is always 4 px; spacing above 4 px
    ///     insets every frame, and the cell height compensates so the frame keeps the source aspect.
    ///   - reservedHeight: Height that the header and the ColorDNA strip will add on top of the
    ///     cells (an upper bound is fine), subtracted from the texture limit. `.adaptCanvas` only.
    ///   - overlayHeight: The **exact** height of the header plus the ColorDNA strip, for the
    ///     fixed-aspect modes (`.letterbox`, `.stretch`): it is subtracted from the grid area so the
    ///     final image keeps the configured aspect. Compute the header for the width
    ///     ``fixedGridCanvasWidth(requestedWidth:mosaicAspectRatio:)``.
    public func planFixedGrid(
        _ grid: GridSpecification,
        sourceAspectRatio: CGFloat,
        mosaicAspectRatio: AspectRatio,
        mosaicWidth: Int,
        spacing: CGFloat = LayoutConfiguration.default.spacing,
        reservedHeight: Int = 0,
        overlayHeight: Int = 0
    ) -> FixedGridPlan {
        let axis = 1...GridSpecification.maximumAxisCount
        guard axis.contains(grid.rows), axis.contains(grid.columns) else {
            return .infeasible(.invalidCount(rows: grid.rows, columns: grid.columns), suggestions: [])
        }
        let cells = grid.rows * grid.columns
        guard cells <= GridSpecification.maximumCellCount else {
            return .infeasible(.tooManyCells(cells: cells, maximum: GridSpecification.maximumCellCount), suggestions: [])
        }
        guard sourceAspectRatio.isFinite, sourceAspectRatio >= 0.01, sourceAspectRatio <= 100 else {
            return .infeasible(.unknownSourceAspect, suggestions: [])
        }
        guard grid.fit != .crop else {
            // Plan G-5. Callers are stopped earlier by `MosaicConfiguration.validate()`; this
            // keeps a direct call honest too.
            return .infeasible(.fitModeUnavailable(grid.fit), suggestions: [])
        }
        if grid.fit != .adaptCanvas {
            return planFixedAspect(
                grid, sourceAspect: Double(sourceAspectRatio), mosaicAspect: Double(mosaicAspectRatio.ratio),
                width: mosaicWidth, spacing: spacing, overlayHeight: overlayHeight
            )
        }
        return planAdaptCanvas(
            grid, sourceAspect: Double(sourceAspectRatio), width: mosaicWidth,
            spacing: spacing, reservedHeight: reservedHeight
        )
    }

    /// The canvas width a fixed-aspect grid really uses: the requested width, reduced when the
    /// canvas of that width and the mosaic aspect would be taller than a texture can be.
    public static func fixedGridCanvasWidth(requestedWidth: Int, mosaicAspectRatio: AspectRatio) -> Int {
        canvasWidth(requestedWidth: requestedWidth, ratio: Double(mosaicAspectRatio.ratio))
    }

    private static func canvasWidth(requestedWidth: Int, ratio: Double) -> Int {
        let width = min(max(requestedWidth, 1), maximumCanvasSide)
        guard ratio.isFinite, ratio > 0 else { return width }
        if Int((Double(width) / ratio).rounded()) > maximumCanvasSide {
            return max(1, min(width, Int((Double(maximumCanvasSide) * ratio).rounded(.down))))
        }
        return width
    }

    /// `.letterbox` and `.stretch`: the canvas keeps the mosaic aspect (overlays included), the
    /// cells fill what is left, and frames are fitted into them (spec section 3.3).
    private func planFixedAspect(
        _ grid: GridSpecification,
        sourceAspect s: Double,
        mosaicAspect: Double,
        width requestedWidth: Int,
        spacing: CGFloat,
        overlayHeight: Int
    ) -> FixedGridPlan {
        let rows = grid.rows
        let columns = grid.columns
        let gutter = Self.fixedGridGutter
        let usableSpacing = spacing.isFinite ? min(max(spacing.rounded(), 0), 1_000_000) : CGFloat(gutter)
        let inset = max(0, Int(usableSpacing) - gutter)
        let width = Self.canvasWidth(requestedWidth: requestedWidth, ratio: mosaicAspect)
        let finalHeight = Int((Double(width) / mosaicAspect).rounded())
        let areaHeight = finalHeight - max(overlayHeight, 0)

        /// Slot and frame sizes of an `R × C` grid in the grid area, or nil when no frame fits.
        func evaluate(_ rows: Int, _ columns: Int) -> (slotWidth: Int, slotHeight: Int, frameWidth: Int, frameHeight: Int)? {
            let slotWidth = (width - (columns - 1) * gutter) / columns
            let slotHeight = (areaHeight - (rows - 1) * gutter) / rows
            let frameWidth = slotWidth - inset
            let frameHeight = slotHeight - inset
            guard frameWidth > 0, frameHeight > 0 else { return nil }
            return (slotWidth, slotHeight, frameWidth, frameHeight)
        }
        func mismatch(_ frameWidth: Int, _ frameHeight: Int) -> (error: Double, fill: Double, slotAspect: Double) {
            let slotAspect = Double(frameWidth) / Double(frameHeight)
            let ratio = slotAspect / s
            return (max(ratio, 1 / ratio) - 1, min(ratio, 1 / ratio), slotAspect)
        }
        /// Up to three other grids that this mode accepts, nearest in cell count first.
        func suggestions() -> [GridSpecification] {
            var found: [(rows: Int, columns: Int, distance: Int)] = []
            let target = rows * columns
            for r in 1...GridSpecification.maximumAxisCount {
                for c in 1...GridSpecification.maximumAxisCount where r * c <= GridSpecification.maximumCellCount {
                    guard let e = evaluate(r, c), min(e.frameWidth, e.frameHeight) >= GridSpecification.minimumFrameSide,
                          mismatch(e.frameWidth, e.frameHeight).error <= grid.aspectTolerance else { continue }
                    found.append((r, c, abs(r * c - target)))
                }
            }
            found.sort { ($0.distance, $0.rows, $0.columns) < ($1.distance, $1.rows, $1.columns) }
            return found.prefix(3).map {
                GridSpecification(rows: $0.rows, columns: $0.columns, fit: grid.fit,
                                  aspectTolerance: grid.aspectTolerance, minimumFill: grid.minimumFill)
            }
        }

        guard let slot = evaluate(rows, columns) else {
            return .infeasible(.cellsTooSmall(shortSide: 0, minimum: GridSpecification.minimumFrameSide), suggestions: [])
        }
        let shortSide = min(slot.frameWidth, slot.frameHeight)
        guard shortSide >= GridSpecification.minimumFrameSide else {
            return .infeasible(.cellsTooSmall(shortSide: shortSide, minimum: GridSpecification.minimumFrameSide), suggestions: [])
        }
        let fit = mismatch(slot.frameWidth, slot.frameHeight)
        var notes: [FixedGridNote] = []
        var frameWidth = slot.frameWidth
        var frameHeight = slot.frameHeight
        if fit.error <= grid.aspectTolerance {
            // Close enough: every mode stretches the frame to the slot.
            notes.append(.stretched(error: fit.error))
        } else if grid.fit == .stretch {
            return .infeasible(.aspectMismatch(cellAspect: fit.slotAspect, sourceAspect: s, error: fit.error), suggestions: suggestions())
        } else if fit.fill < grid.minimumFill {
            return .infeasible(.fillTooLow(fill: fit.fill, minimum: grid.minimumFill), suggestions: suggestions())
        } else {
            if fit.slotAspect > s {
                frameWidth = Int((Double(slot.frameHeight) * s).rounded())      // pillarbox
            } else {
                frameHeight = Int((Double(slot.frameWidth) / s).rounded())      // letterbox
            }
            frameWidth = max(1, min(frameWidth, slot.frameWidth))
            frameHeight = max(1, min(frameHeight, slot.frameHeight))
            notes.append(.letterboxed(fill: fit.fill))
        }

        // The grid is centered in the canvas: the floor of the slot sizes leaves a few pixels over.
        let gridWidth = columns * slot.slotWidth + (columns - 1) * gutter
        let gridHeight = rows * slot.slotHeight + (rows - 1) * gutter
        let originX = (width - gridWidth) / 2
        let originY = (areaHeight - gridHeight) / 2
        // The renderer insets every rect by `inset / 2` per side, so the rect is the frame plus the inset.
        let rect = CGSize(width: frameWidth + inset, height: frameHeight + inset)
        let offsetX = (slot.slotWidth - Int(rect.width)) / 2
        let offsetY = (slot.slotHeight - Int(rect.height)) / 2
        var positions: [(x: Int, y: Int)] = []
        positions.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                positions.append((
                    x: originX + column * (slot.slotWidth + gutter) + offsetX,
                    y: originY + row * (slot.slotHeight + gutter) + offsetY
                ))
            }
        }
        let layout = MosaicLayout(
            rows: rows, cols: columns, thumbnailSize: rect, positions: positions,
            thumbCount: rows * columns,
            thumbnailSizes: [CGSize](repeating: rect, count: rows * columns),
            mosaicSize: CGSize(width: width, height: areaHeight)
        )
        if width < requestedWidth { notes.insert(.widthReduced(from: requestedWidth, to: width), at: 0) }
        return .layout(layout, effectiveWidth: width, notes: notes)
    }

    /// `.adaptCanvas`: whole-pixel cells that all have the source aspect.
    private func planAdaptCanvas(
        _ grid: GridSpecification,
        sourceAspect s: Double,
        width requestedWidth: Int,
        spacing: CGFloat,
        reservedHeight: Int
    ) -> FixedGridPlan {
        let rows = grid.rows
        let columns = grid.columns
        let gutter = Self.fixedGridGutter
        // `spacing` comes from a public mutable property or from decoding: keep the Int conversion
        // in range (NaN and infinity count as the default; a huge value is rejected as 'cells too small').
        let usableSpacing = spacing.isFinite ? min(max(spacing.rounded(), 0), 1_000_000) : CGFloat(gutter)
        let inset = max(0, Int(usableSpacing) - gutter)
        let width = min(max(requestedWidth, 1), Self.maximumCanvasSide)
        let maximumHeight = max(1, Self.maximumCanvasSide - max(reservedHeight, 0))

        /// Slot size for a slot width: the frame (slot minus the inset) has the source aspect.
        func slot(_ slotWidth: Int) -> (width: Int, height: Int, frameWidth: Int, frameHeight: Int) {
            let frameWidth = slotWidth - inset
            let frameHeight = Int((Double(frameWidth) / s).rounded())
            return (slotWidth, frameHeight + inset, frameWidth, frameHeight)
        }
        func canvasHeight(_ slotHeight: Int) -> Int { rows * slotHeight + (rows - 1) * gutter }

        let widest = (width - (columns - 1) * gutter) / columns
        guard widest > inset else {
            return .infeasible(.cellsTooSmall(shortSide: max(widest - inset, 0), minimum: GridSpecification.minimumFrameSide), suggestions: [])
        }
        // The canvas height grows with the slot width, so the widest slot that still fits the
        // texture limit comes from a binary search (at most 14 steps).
        var low = inset + 1
        var high = widest
        guard canvasHeight(slot(low).height) <= maximumHeight else {
            return .infeasible(.canvasTooTall(requiredHeight: canvasHeight(slot(low).height), maximum: maximumHeight), suggestions: [])
        }
        while low < high {
            let middle = (low + high + 1) / 2
            if canvasHeight(slot(middle).height) <= maximumHeight { low = middle } else { high = middle - 1 }
        }
        let chosen = slot(low)
        let shortSide = min(chosen.frameWidth, chosen.frameHeight)
        guard shortSide >= GridSpecification.minimumFrameSide else {
            return .infeasible(.cellsTooSmall(shortSide: shortSide, minimum: GridSpecification.minimumFrameSide), suggestions: [])
        }

        let canvasWidth = columns * chosen.width + (columns - 1) * gutter
        let size = CGSize(width: chosen.width, height: chosen.height)
        var positions: [(x: Int, y: Int)] = []
        positions.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                positions.append((x: column * (chosen.width + gutter), y: row * (chosen.height + gutter)))
            }
        }
        let layout = MosaicLayout(
            rows: rows, cols: columns, thumbnailSize: size, positions: positions,
            thumbCount: rows * columns,
            thumbnailSizes: [CGSize](repeating: size, count: rows * columns),
            mosaicSize: CGSize(width: canvasWidth, height: canvasHeight(chosen.height))
        )
        var notes: [FixedGridNote] = []
        if canvasWidth < requestedWidth { notes.append(.widthReduced(from: requestedWidth, to: canvasWidth)) }
        return .layout(layout, effectiveWidth: canvasWidth, notes: notes)
    }
}
