import Foundation
import CoreGraphics

/// A platform-independent, Codable color representation for mosaic backgrounds.
public struct MosaicColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Mid-gray — the default solid background color.
    public static let defaultGray = MosaicColor(red: 0.5, green: 0.5, blue: 0.5)

    /// Converts to a CGColor for use in Core Graphics rendering.
    public var cgColor: CGColor {
        CGColor(red: red, green: blue, blue: blue, alpha: alpha)
    }
}

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

    /// Optional custom output directory. When nil, uses a default derived from the video's location.
    public var outputdirectory:  URL? = nil

    /// Whether to include the full directory path in the filename.
    public var fullPathInName: Bool

    /// Whether to derive the background color from the movie's dominant colors.
    /// When `true` (default), a blurred gradient built from the video's dominant
    /// colors is used as the mosaic background.
    /// When `false`, `backgroundColor` is used instead.
    public var useMovieColorsForBg: Bool

    /// The solid background color used when `useMovieColorsForBg` is `false`.
    /// Ignored when `useMovieColorsForBg` is `true`.
    public var backgroundColor: MosaicColor

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
        outputdirectory: URL? = nil,
        fullPathInName: Bool = false,
        useMovieColorsForBg: Bool = true,
        backgroundColor: MosaicColor = .defaultGray
    ) {
        self.width = width
        self.density = density
        self.format = format
        self.layout = layout
        self.includeMetadata = includeMetadata
        self.useAccurateTimestamps = useAccurateTimestamps
        self.compressionQuality = compressionQuality
        self.outputdirectory = outputdirectory
        self.fullPathInName = fullPathInName
        self.useMovieColorsForBg = useMovieColorsForBg
        self.backgroundColor = backgroundColor
    }

    /// Creates a MosaicConfiguration instance.
    /// - Note: The `forIphone` parameter no longer controls the background color.
    ///   Use `useMovieColorsForBg` and `backgroundColor` instead.
    @available(*, deprecated, renamed: "init(width:density:format:layout:includeMetadata:useAccurateTimestamps:compressionQuality:outputdirectory:fullPathInName:useMovieColorsForBg:backgroundColor:)")
    public init(
        width: Int = 5120,
        density: DensityConfig = .default,
        format: OutputFormat = .heif,
        layout: LayoutConfiguration = .default,
        includeMetadata: Bool = true,
        useAccurateTimestamps: Bool = false,
        compressionQuality: Double = 0.4,
        outputdirectory: URL? = nil,
        fullPathInName: Bool = false,
        forIphone: Bool

    ) {
        self.width = width
        self.density = density
        self.format = format
        self.layout = layout
        self.includeMetadata = includeMetadata
        self.useAccurateTimestamps = useAccurateTimestamps
        self.compressionQuality = compressionQuality
        self.outputdirectory = outputdirectory
        self.fullPathInName = fullPathInName
        // forIphone == true previously meant solid gray; map that to the new params
        self.useMovieColorsForBg = !forIphone
        self.backgroundColor = .defaultGray
    }

    /// Default configuration for mosaic generation
    public static var `default`: MosaicConfiguration {
        MosaicConfiguration(
            width: 4000,
            density: .xl,
            format: .heif,
            layout: LayoutConfiguration(layoutType: .custom),
            compressionQuality: 0.4
        )
    }

    public mutating func updateAspectRatio(new: AspectRatio)
    {
        self.layout.aspectRatio = new
    }

    // MARK: - Helper Methods

    /// Generate a configuration hash string for folder naming
    /// Format: "{width}_{density}_{aspectRatio}_{layoutType}"
    /// Example: "5120_XL_16-9_custom"
    public var configurationHash: String {
        let aspectRatioString = layout.aspectRatio.rawValue.replacingOccurrences(of: ":", with: "-")
        return "\(width)_\(density.name)_\(aspectRatioString)_\(layout.layoutType.rawValue)"
    }

    /// Sanitize a string for use in file paths
    private static func sanitizeForFilePath(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:@#$%^&*(){}[]|\\<>?\"'+,=!`~;")
        let components = string.components(separatedBy: invalidCharacters)
        return components.joined(separator: "_").replacingOccurrences(of: " ", with: "_")
    }

    /// Generate the structured output path
    /// Format: {rootDir}/{service}/{creator}/{configHash}/
    /// - Parameters:
    ///   - rootDirectory: The root directory for output
    ///   - videoInput: The video input containing organizational metadata
    /// - Returns: The full output directory URL
    public func generateOutputDirectory(rootDirectory: URL, videoInput: VideoInput) -> URL {
        var path = rootDirectory

        // Add service name if available
        if let service = videoInput.serviceName {
            path = path.appendingPathComponent(Self.sanitizeForFilePath(service))
        }

        // Add creator name if available
        if let creator = videoInput.creatorName {
            path = path.appendingPathComponent(Self.sanitizeForFilePath(creator))
        }

        // Add configuration hash
        path = path.appendingPathComponent(configurationHash)

        return path
    }

    /// Generate filename with post ID prefix
    /// Format: {postID}_{originalFilename}_{configHash}.{extension}
    /// Or with fullPathInName: _volumes_ext-3_dir1_dir2_{originalFilename}_{configHash}.{extension}
    /// - Parameters:
    ///   - originalFilename: The original video filename
    ///   - videoInput: The video input containing organizational metadata
    /// - Returns: The sanitized filename with configuration hash
    public func generateFilename(originalFilename: String, videoInput: VideoInput) -> String {
        let sanitizedName = Self.sanitizeForFilePath(originalFilename)

        // Build base filename
        var filename: String

        if fullPathInName {
            // Include full path: _volumes_ext-3_dir1_dir2_movie
            let fullPath = videoInput.url.deletingLastPathComponent().path
            let pathComponents = fullPath.components(separatedBy: "/").filter { !$0.isEmpty }
            let sanitizedPath = pathComponents.map { Self.sanitizeForFilePath($0) }.joined(separator: "_")
            filename = "_\(sanitizedPath)_\(sanitizedName)"
        } else {
            if let postID = videoInput.postID {
                filename = "\(Self.sanitizeForFilePath(postID))_\(sanitizedName)"
            } else {
                filename = sanitizedName
            }
        }

        // Truncate if too long (reserve space for suffix)
        let maxBaseLength = 200
        if filename.count > maxBaseLength {
            filename = String(filename.prefix(maxBaseLength))
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
