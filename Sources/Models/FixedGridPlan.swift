import Foundation

/// The result of planning a ``LayoutType/fixedGrid`` layout: either a layout, or the reason there
/// is none. Returned by ``LayoutProcessor/planFixedGrid(_:sourceAspectRatio:mosaicAspectRatio:mosaicWidth:spacing:reservedHeight:overlayHeight:)``.
public enum FixedGridPlan: Sendable {
    /// The grid fits. `effectiveWidth` is the canvas width actually used (at most the requested
    /// width); `notes` list every adjustment that was made.
    case layout(MosaicLayout, effectiveWidth: Int, notes: [FixedGridNote])
    /// The grid cannot be laid out as asked. `suggestions` are grids that would work (empty
    /// for reasons no other grid fixes).
    case infeasible(FixedGridIssue, suggestions: [GridSpecification])
}

/// Why a grid cannot be laid out. Machine-readable, with the numbers, so an app can localize it
/// or highlight a field; ``explanation`` is the English text MosaicKit's own errors use.
public enum FixedGridIssue: Sendable, Equatable {
    /// Rows or columns outside `1...GridSpecification.maximumAxisCount`.
    case invalidCount(rows: Int, columns: Int)
    /// More than ``GridSpecification/maximumCellCount`` cells.
    case tooManyCells(cells: Int, maximum: Int)
    /// A frame would be narrower or shorter than ``GridSpecification/minimumFrameSide`` pixels.
    case cellsTooSmall(shortSide: Int, minimum: Int)
    /// The cell aspect differs from the source aspect by more than the tolerance (fixed-aspect modes).
    case aspectMismatch(cellAspect: Double, sourceAspect: Double, error: Double)
    /// The picture would cover too little of the cell (fixed-aspect modes).
    case fillTooLow(fill: Double, minimum: Double)
    /// The grid is taller than a texture can be, even at the smallest allowed frame size.
    case canvasTooTall(requiredHeight: Int, maximum: Int)
    /// The source's display aspect ratio is not known or not usable.
    case unknownSourceAspect
    /// The fit mode is not implemented. Every ``GridFitMode`` is implemented now, so this is never
    /// produced; the case stays so existing `switch` statements keep compiling.
    case fitModeUnavailable(GridFitMode)

    /// An English description with the numbers, for error messages and logs.
    public var explanation: String {
        switch self {
        case .invalidCount(let rows, let columns):
            return "A grid needs between 1 and \(GridSpecification.maximumAxisCount) rows and columns (got \(rows) × \(columns))"
        case .tooManyCells(let cells, let maximum):
            return "A grid may have at most \(maximum) cells (this one has \(cells))"
        case .cellsTooSmall(let shortSide, let minimum):
            return "The frames would be \(shortSide) px on their short side; the minimum is \(minimum) px. Use fewer rows or columns, or a larger width"
        case .aspectMismatch(let cellAspect, let sourceAspect, let error):
            return "The cells are \(Self.ratio(cellAspect)):1 but the video is \(Self.ratio(sourceAspect)):1 (\(Self.percent(error)) off). Use fit .adaptCanvas, or another grid"
        case .fillTooLow(let fill, let minimum):
            return "The picture would fill only \(Self.percent(fill)) of each cell; the minimum is \(Self.percent(minimum)). Use fit .adaptCanvas, or another grid"
        case .canvasTooTall(let required, let maximum):
            return "The grid would be \(required) px tall; the limit is \(maximum) px. Use fewer rows or a narrower canvas"
        case .unknownSourceAspect:
            return "The video's dimensions are not known; inspect it with VideoInput(from:) first"
        case .fitModeUnavailable(let mode):
            return "The grid fit mode .\(mode.rawValue) is not available in this build yet; use .adaptCanvas"
        }
    }

    private static func ratio(_ value: Double) -> String { String(format: "%.2f", value) }
    private static func percent(_ value: Double) -> String { String(format: "%.1f %%", value * 100) }
}

/// An adjustment the planner made to a feasible grid.
public enum FixedGridNote: Sendable, Equatable {
    /// The canvas is narrower than requested (trimmed to whole cells, or shrunk to fit the height limit).
    case widthReduced(from: Int, to: Int)
    /// Frames are stretched, within the tolerance.
    case stretched(error: Double)
    /// Frames are letterboxed or pillarboxed and cover `fill` of the cell.
    case letterboxed(fill: Double)
    /// Frames are cropped and `retained` of the picture survives.
    case cropped(retained: Double)
}
