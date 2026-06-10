import Foundation
import AVFoundation
import CoreGraphics

/// A structure containing metadata about a video file used for mosaic generation.
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

/// A model representing a video input file and its extracted metadata.
public struct VideoInput: Codable, Hashable, Sendable {
    // MARK: - Properties

    /// A unique identifier for the video input.
    public let id: UUID

    /// The file URL to the source video file.
    public let url: URL

    /// An optional title for the video, defaulting to the filename.
    public let title: String

    /// The duration of the video in seconds, if available.
    public let duration: TimeInterval?

    /// The width of the video in pixels, if available.
    public let width: Double?

    /// The height of the video in pixels, if available.
    public let height: Double?

    /// The frame rate of the video, if available.
    public let frameRate: Double?

    /// The file size of the video in bytes, if available.
    public let fileSize: Int64?

    /// Additional metadata details like codec and bitrate.
    public let metadata: VideoMetadata

    /// An optional post ID associated with the video, used in naming outputs.
    public let postID: String?

    // MARK: - Computed Properties

    /// The resolution of the video as a `CGSize`, if available.
    public var resolution: CGSize? {
        guard let width = width, let height = height else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The aspect ratio of the video (width divided by height), if available.
    public var aspectRatio: Double? {
        guard let width = width, let height = height, height > 0 else { return nil }
        return width / height
    }

    // MARK: - Initialization

    /// Initializes a new video input with explicit values and automatically extracts metadata from the file.
    ///
    /// - Parameters:
    ///   - id: A unique identifier.
    ///   - url: The file URL of the video.
    ///   - title: An optional custom title.
    ///   - duration: The duration in seconds.
    ///   - width: The width in pixels.
    ///   - height: The height in pixels.
    ///   - frameRate: The frame rate.
    ///   - fileSize: The file size in bytes.
    ///   - metadata: Additional video metadata.
    ///   - postID: An optional post ID.
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
        postID: String? = nil
    ) async {
        do {
            let extractor = VideoMetadataExtractor()
            let videodata = try await extractor.extractMetadataValues(from: url)
            self.id = id
            self.url = url
            self.title = title ?? url.deletingPathExtension().lastPathComponent
            self.duration = videodata.duration
            self.width = videodata.width
            self.height = videodata.height
            self.frameRate = videodata.frameRate
            self.fileSize = videodata.fileSize
            self.metadata = VideoMetadata(codec: videodata.videoCodec, bitrate: videodata.bitrate)
            self.postID = postID
        } catch {
            self.id = id
            self.url = url
            self.title = title ?? url.deletingPathExtension().lastPathComponent
            self.duration = 0
            self.width = 0
            self.height = 0
            self.frameRate = 0
            self.fileSize = 0
            self.metadata = VideoMetadata(codec: "unknown", bitrate: 0)
            self.postID = postID
        }
    }

    /// Initializes a new video input from a URL, acquiring security-scoped access before extracting metadata.
    ///
    /// - Parameters:
    ///   - url: The file URL of the video.
    ///   - postID: An optional post ID.
    /// - Throws: A `MosaicError.invalidVideo` if the security-scoped resource cannot be accessed.
    public init(from url: URL, postID: String? = nil) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw MosaicError.invalidVideo("Failed to access security-scoped resource")
        }
        let extractor = VideoMetadataExtractor()
        let videodata = try await extractor.extractMetadataValues(from: url)
        await self.init(
            url: url,
            duration: videodata.duration,
            width: videodata.width,
            height: videodata.height,
            frameRate: videodata.frameRate,
            fileSize: videodata.fileSize,
            metadata: VideoMetadata(codec: videodata.videoCodec, bitrate: videodata.bitrate),
            postID: postID
        )
    }
}
