import Foundation

/// How a fixed grid reconciles the grid with the source's aspect ratio.
///
/// Raw values are persisted and appear in output paths: never rename them.
public enum GridFitMode: String, Codable, Sendable, CaseIterable {
    /// Default. The canvas height follows the grid: every cell gets the source aspect.
    /// `LayoutConfiguration.aspectRatio` does not shape the canvas. Frames are never distorted,
    /// cropped or letterboxed.
    case adaptCanvas
    /// The canvas keeps `LayoutConfiguration.aspectRatio`. Frames keep their aspect ratio and are
    /// centered in their cell (bars show the background).
    case letterbox
    /// The canvas keeps `LayoutConfiguration.aspectRatio`. Frames fill the cell; the excess of the
    /// longer side is cropped, centered.
    case crop
    /// The canvas keeps `LayoutConfiguration.aspectRatio`. Frames are stretched, but only up to
    /// ``GridSpecification/aspectTolerance``; beyond that the request is rejected.
    case stretch
}

/// The rows and columns of a ``LayoutType/fixedGrid`` layout, and how the grid is fitted to the
/// source's aspect ratio. Set it on ``LayoutConfiguration/grid``.
public struct GridSpecification: Codable, Sendable, Hashable {
    /// Number of rows, `1...maximumAxisCount`.
    public var rows: Int
    /// Number of columns, `1...maximumAxisCount`.
    public var columns: Int
    /// How the grid is fitted to the source's aspect ratio. Default ``GridFitMode/adaptCanvas``.
    public var fit: GridFitMode
    /// Largest accepted relative difference between the cell aspect and the source aspect before
    /// the fit mode must act (letterbox, crop) or refuse (stretch). Default `0.02` (2 %), range
    /// `0...0.25`. Not read by ``GridFitMode/adaptCanvas``.
    public var aspectTolerance: Double
    /// Fixed-aspect modes only: the smallest fraction of the cell area that may be covered by the
    /// picture (letterbox) or of the picture that may survive (crop). Default `0.5`, range
    /// `0.1...1`.
    public var minimumFill: Double

    /// The most rows or columns a grid may have.
    public static let maximumAxisCount = 50
    /// The most cells (`rows × columns`) a grid may have.
    public static let maximumCellCount = 1000
    /// The smallest short side, in pixels, a frame may have inside its cell.
    public static let minimumFrameSide = 40

    public init(
        rows: Int,
        columns: Int,
        fit: GridFitMode = .adaptCanvas,
        aspectTolerance: Double = 0.02,
        minimumFill: Double = 0.5
    ) {
        self.rows = rows
        self.columns = columns
        self.fit = fit
        self.aspectTolerance = aspectTolerance
        self.minimumFill = minimumFill
    }

    private enum CodingKeys: String, CodingKey { case rows, columns, fit, aspectTolerance, minimumFill }

    /// `fit`, `aspectTolerance` and `minimumFill` decode with `decodeIfPresent` and a default, so
    /// a later release can add keys the same way.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rows: try container.decode(Int.self, forKey: .rows),
            columns: try container.decode(Int.self, forKey: .columns),
            fit: try container.decodeIfPresent(GridFitMode.self, forKey: .fit) ?? .adaptCanvas,
            aspectTolerance: try container.decodeIfPresent(Double.self, forKey: .aspectTolerance) ?? 0.02,
            minimumFill: try container.decodeIfPresent(Double.self, forKey: .minimumFill) ?? 0.5
        )
    }
}
