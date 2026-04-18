import Foundation
import CoreGraphics
import ImageIO

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
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
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

    /// Overlay and annotation configuration: per-frame labels, header fields,
    /// watermark, and Color DNA strip.
    public var overlay: OverlayConfiguration

    /// Controls whether an animated GIF is created and how.
    public var gifMode: GifCreationMode

    /// Controls the output dimensions of the animated GIF frames.
    public var gifSize: GifSize

    /// Container format for the animated image export.
    public var animatedFormat: AnimatedFormat

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
        backgroundColor: MosaicColor = .defaultGray,
        overlay: OverlayConfiguration = .default,
        gifMode: GifCreationMode = .disabled,
        gifSize: GifSize = .nochange,
        animatedFormat: AnimatedFormat = .webp
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
        self.overlay = overlay
        self.gifMode = gifMode
        self.gifSize = gifSize
        self.animatedFormat = animatedFormat
    }
    
    public init(
        density: DensityConfig = .default,
        outputdirectory: URL? = nil,
        fullPathInName: Bool = false,
        gifMode: GifCreationMode = .disabled,
        gifSize: GifSize = .nochange,
        animatedFormat: AnimatedFormat = .webp
    ) {
        self.width = 2500
        self.density = density
        self.format = .heif
        self.layout = .default
        self.includeMetadata = true
        self.useAccurateTimestamps = false
        self.compressionQuality = 0.3
        self.outputdirectory = outputdirectory
        self.fullPathInName = fullPathInName
        self.useMovieColorsForBg = false
        self.backgroundColor = .defaultGray
        self.overlay = .default
        self.gifMode = gifMode
        self.gifSize = gifSize
        self.animatedFormat = animatedFormat
    }
    
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
        backgroundColor: MosaicColor = .defaultGray,
        overlay: OverlayConfiguration = .default,
        
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
        self.overlay = overlay
        self.gifMode = .disabled
        self.gifSize = .small
        self.animatedFormat = .webp
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
        self.overlay = .default
        self.gifMode = .disabled
        self.gifSize = .nochange
        self.animatedFormat = .gif
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

    /// Returns the URL where the animated image would be saved for a given video.
    /// Placed in the same directory as the mosaic, same base filename, with the
    /// extension determined by `animatedFormat` (`.gif`, `.heics`, or `.webp`).
    public func animatedOutputURL(for video: VideoInput) -> URL {
        let rootFolder = outputdirectory ?? video.url.deletingLastPathComponent()
        let outputDir = generateOutputDirectory(rootDirectory: rootFolder, videoInput: video)
        let originalFilename = video.url.deletingPathExtension().lastPathComponent
        let mosaicFilename = generateFilename(originalFilename: originalFilename, videoInput: video)
        
        let animFilename = "\(gifSize.name) -" + (mosaicFilename as NSString).deletingPathExtension + ".\(animatedFormat.fileExtension)"
        return outputDir.appendingPathComponent(animFilename)
    }

    /// Returns the URL where the animated GIF would be saved for a given video.
    @available(*, deprecated, renamed: "animatedOutputURL(for:)")
    public func gifOutputURL(for video: VideoInput) -> URL {
        animatedOutputURL(for: video)
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

/// Output container format for the animated image export.
public enum AnimatedFormat: String, Codable, Sendable {
    /// Animated GIF (`com.compuserve.gif`). Universal compatibility.
    case gif
    /// Animated HEIC sequence (`public.heics`). Better quality and compression; Apple platforms only.
    case heic
    /// Animated WebP (`org.webmproject.webp`). Good compression; wide web compatibility.
    case webp

    /// File extension for the format.
    public var fileExtension: String {
        switch self {
        case .gif:  return "gif"
        case .heic: return "heics"
        case .webp: return "webp"
        }
    }

    /// UTI identifier used by `CGImageDestination`.
    public var uti: String {
        switch self {
        case .gif:  return "com.compuserve.gif"
        case .heic: return "public.heics"
        case .webp: return "org.webmproject.webp"
        }
    }

    /// Whether this format can be written on the current platform.
    /// GIF and HEIC use `CGImageDestination`; WebP uses the bundled `webp.swift` encoder (always available).
    public var isWritable: Bool {
        if self == .webp { return true }
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains(uti)
    }
}

/// Controls whether and how an animated GIF is created alongside the mosaic.
public enum GifCreationMode: String, Codable, Sendable {
    /// No GIF is created (default).
    case disabled
    /// Create both the mosaic and an animated GIF.
    case withMosaic
    /// Create only the animated GIF, skipping mosaic generation.
    case gifOnly
    
    
}

/// Output size preset for the animated GIF frames.
public enum GifSize: String, Codable, Sendable {
    /// Same dimensions as the source video (no downscaling).
    case nochange
    /// Scale frames down so height ≤ 720 px (720p).
    case large
    /// Scale frames down so height ≤ 540 px (540p).
    case small
    
    public var name: String {
        switch self {
        case .nochange: return "nochange"
        case .large: return "large"
        case .small: return "small"
            
        }
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
