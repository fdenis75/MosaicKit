import Foundation
import CoreGraphics

/// Configuration for mosaic generation.
public struct MosaicConfiguration: Codable, Sendable {
    // MARK: - Properties

    /// The width of the output mosaic in pixels.
    public var width: Int

    /// The density configuration for frame extraction.
    public var density: DensityConfig

    /// The output format for the mosaic.
    public var format: OutputFormat

    /// The layout configuration for the mosaic.
    public var layout: LayoutConfiguration

    /// Whether to include metadata overlay.
    public var includeMetadata: Bool

    /// Whether to use accurate timestamps for frame extraction.
    public var useAccurateTimestamps: Bool

    /// The compression quality for JPEG/HEIF output (0.0 to 1.0).
    public var compressionQuality: Double

    public var outputdirectory:  URL? = nil
    
    // MARK: - Initialization

    /// Creates a new MosaicConfiguration instance.
    public init(
        width: Int = 5120,
        density: DensityConfig = .default,
        format: OutputFormat = .heif,
        layout: LayoutConfiguration = .default,
        includeMetadata: Bool = true,
        useAccurateTimestamps: Bool = false,
    compressionQuality: Double = 0.4,
        ourputdirectory: URL? = nil
    ) {
        self.width = width
        self.density = density
        self.format = format
        self.layout = layout
        self.includeMetadata = includeMetadata
        self.useAccurateTimestamps = useAccurateTimestamps
        self.compressionQuality = compressionQuality
        self.outputdirectory = ourputdirectory
    }

    /// Default configuration for mosaic generation
    public static var `default`: MosaicConfiguration {
        MosaicConfiguration(
            width: 4000,
            density: .xl,
            format: .heif,
            layout: .default,
            compressionQuality: 0.4
        )
    }
}

/// The output format for mosaic images.
public enum OutputFormat: String, Codable, Sendable {
    /// JPEG format.
    case jpeg
    /// PNG format.
    case png
    /// HEIF format (High Efficiency Image Format).
    case heif

    /// File extension for the format
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heif: return "heic"
        }
    }
}
