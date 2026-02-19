import Foundation
import AVFoundation
import CoreGraphics

/// Metadata about a video file for mosaic generation
public struct VideoMetadata: Codable, Hashable, Sendable {
    public var codec: String?
    public var bitrate: Int64?
    public var custom: [String: String]

    public init(codec: String? = nil, bitrate: Int64? = nil, custom: [String: String] = [:]) {
        self.codec = codec
        self.bitrate = bitrate
        self.custom = custom
    }
}

/// A simplified video input model for mosaic generation
public struct VideoInput: Codable, Hashable, Sendable {
    // MARK: - Properties

    /// Unique identifier
    public let id: UUID

    /// URL to the video file
    public let url: URL

    /// Optional title (defaults to filename)
    public let title: String

    /// Video duration in seconds
    public let duration: TimeInterval?

    /// Video width in pixels
    public let width: Double?

    /// Video height in pixels
    public let height: Double?

    /// Video frame rate
    public let frameRate: Double?

    /// File size in bytes
    public let fileSize: Int64?

    /// Video metadata (codec, bitrate, etc.)
    public let metadata: VideoMetadata

    // MARK: - Organizational Metadata

    /// Service name (e.g., "onlyfans", "fansly", "candfans")
    public let serviceName: String?

    /// Creator name for organizing output
    public let creatorName: String?

    /// Post ID for file naming
    public let postID: String?

    // MARK: - Computed Properties

    /// Video resolution as CGSize
    public var resolution: CGSize? {
        guard let width = width, let height = height else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Aspect ratio (width / height)
    public var aspectRatio: Double? {
        guard let width = width, let height = height, height > 0 else { return nil }
        return width / height
    }

    // MARK: - Initialization

    /// Initialize with explicit values
    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        duration: TimeInterval? = nil,
        width: Double? = nil,
        height: Double? = nil,
        frameRate: Double? = nil,
        fileSize: Int64? = nil,
        metadata: VideoMetadata = VideoMetadata(),
        serviceName: String? = nil,
        creatorName: String? = nil,
        postID: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.fileSize = fileSize
        self.metadata = metadata
        self.serviceName = serviceName
        self.creatorName = creatorName
        self.postID = postID
    }

    /// Initialize from URL and extract metadata
    /// - Parameters:
    ///   - url: URL to the video file
    ///   - serviceName: Optional service name for organization
    ///   - creatorName: Optional creator name for organization
    ///   - postID: Optional post ID for file naming
    /// - Throws: Error if video cannot be accessed or metadata cannot be extracted
    public init(from url: URL, serviceName: String? = nil, creatorName: String? = nil, postID: String? = nil) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw MosaicError.invalidVideo("Failed to access security-scoped resource")
        }
        
        
        let asset = AVURLAsset(url: url)
        
        // Load all tracks
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw MosaicError.invalidVideo("No video track found")
        }
        
        // Extract basic properties
        let duration = try await asset.load(.duration).seconds
        let (naturalSize,nominalFrameRate,formatDescriptions,estimatedDataRate) = try await videoTrack.load(.naturalSize, .nominalFrameRate,.formatDescriptions,.estimatedDataRate)
        
        // Get file size
        var fileSize: Int64?
        if url.isFileURL {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = attributes?[.size] as? Int64
        }
        
        // Extract codec and bitrate
        var codec: String?
        var bitrate: Int64?
        
        if let formatDescription = formatDescriptions.first {
            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
            
            // Convert FourCC code to string
            let chars = [
                UInt8((mediaSubType >> 24) & 0xFF),
                UInt8((mediaSubType >> 16) & 0xFF),
                UInt8((mediaSubType >> 8) & 0xFF),
                UInt8(mediaSubType & 0xFF)
            ]
            codec = String(bytes: chars, encoding: .utf8)
        }
        
        // Try to get bitrate
        bitrate = Int64(estimatedDataRate)
        
        self.init(
            url: url,
            duration: duration,
            width: Double(naturalSize.width),
            height: Double(naturalSize.height),
            frameRate: Double(nominalFrameRate),
            fileSize: fileSize,
            metadata: VideoMetadata(codec: codec, bitrate: bitrate),
            serviceName: serviceName,
            creatorName: creatorName,
            postID: postID
        )
    }
}
