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
    ///     cells (an upper bound is fine), subtracted from the texture limit.
    public func planFixedGrid(
        _ grid: GridSpecification,
        sourceAspectRatio: CGFloat,
        mosaicAspectRatio: AspectRatio,
        mosaicWidth: Int,
        spacing: CGFloat = LayoutConfiguration.default.spacing,
        reservedHeight: Int = 0
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
        guard grid.fit == .adaptCanvas else {
            // Plan G-4 (letterbox, stretch) and G-5 (crop). Callers are stopped earlier by
            // `MosaicConfiguration.validate()`; this keeps a direct call honest too.
            return .infeasible(.fitModeUnavailable(grid.fit), suggestions: [])
        }
        return planAdaptCanvas(
            grid, sourceAspect: Double(sourceAspectRatio), width: mosaicWidth,
            spacing: spacing, reservedHeight: reservedHeight
        )
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
