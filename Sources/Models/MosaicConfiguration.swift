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

    // MARK: - Metadata for Structured Output

    /// The service name (e.g., "onlyfans", "fansly", "candfans")
    public var serviceName: String?

    /// The creator name for organizing output
    public var creatorName: String?

    /// The post ID for file naming
    public var postID: String?

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
        ourputdirectory: URL? = nil,
        serviceName: String? = nil,
        creatorName: String? = nil,
        postID: String? = nil
    ) {
        self.width = width
        self.density = density
        self.format = format
        self.layout = layout
        self.includeMetadata = includeMetadata
        self.useAccurateTimestamps = useAccurateTimestamps
        self.compressionQuality = compressionQuality
        self.outputdirectory = ourputdirectory
        self.serviceName = serviceName
        self.creatorName = creatorName
        self.postID = postID
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

    // MARK: - Helper Methods

    /// Generate a configuration hash string for folder naming
    /// Format: "{width}_{density}_{aspectRatio}"
    /// Example: "5120_XL_16-9"
    public var configurationHash: String {
        let aspectRatioString = layout.aspectRatio.description.replacingOccurrences(of: ":", with: "-")
        return "\(width)_\(density.name)_\(aspectRatioString)"
    }

    /// Sanitize a string for use in file paths
    private static func sanitizeForFilePath(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:@#$%^&*(){}[]|\\<>?\"'+,=!`~;")
        let components = string.components(separatedBy: invalidCharacters)
        return components.joined(separator: "_").replacingOccurrences(of: " ", with: "_")
    }

    /// Generate the structured output path
    /// Format: {rootDir}/{service}/{creator}/{configHash}/
    public func generateOutputDirectory(rootDirectory: URL) -> URL {
        var path = rootDirectory

        // Add service name if available
        if let service = serviceName {
            path = path.appendingPathComponent(Self.sanitizeForFilePath(service))
        }

        // Add creator name if available
        if let creator = creatorName {
            path = path.appendingPathComponent(Self.sanitizeForFilePath(creator))
        }

        // Add configuration hash
        path = path.appendingPathComponent(configurationHash)

        return path
    }

    /// Generate filename with post ID prefix
    /// Format: {postID}_{originalFilename}_{configHash}.{extension}
    public func generateFilename(originalFilename: String) -> String {
        var sanitizedName = Self.sanitizeForFilePath(originalFilename)

        // Remove existing extension
        if let lastDot = sanitizedName.lastIndex(of: ".") {
            sanitizedName = String(sanitizedName[..<lastDot])
        }

        // Truncate if too long (reserve space for postID and suffix)
        let maxBaseLength = 150
        if sanitizedName.count > maxBaseLength {
            sanitizedName = String(sanitizedName.prefix(maxBaseLength))
        }

        // Build filename with optional post ID prefix
        var filename: String
        if let postID = postID {
            filename = "\(Self.sanitizeForFilePath(postID))_\(sanitizedName)"
        } else {
            filename = sanitizedName
        }

        // Add config hash and extension
        return "\(filename)_\(configurationHash).\(format.fileExtension)"
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
