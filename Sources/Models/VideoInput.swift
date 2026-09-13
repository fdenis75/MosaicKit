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

    /// Creates a canonical input from already inspected metadata without performing I/O.
    public init(
        canonicalID: UUID = UUID(), url: URL, title: String? = nil,
        duration: TimeInterval? = nil, width: Double? = nil, height: Double? = nil,
        frameRate: Double? = nil, fileSize: Int64? = nil,
        metadata: VideoMetadata = VideoMetadata(), postID: String? = nil
    ) {
        self.id = canonicalID
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.fileSize = fileSize
        self.metadata = metadata
        self.postID = postID
    }

    /// Copies inspected metadata with a new execution identity, without reading the source.
    public func withID(_ id: UUID) -> VideoInput {
        VideoInput(canonicalID: id, url: url, title: title, duration: duration,
                   width: width, height: height, frameRate: frameRate, fileSize: fileSize,
                   metadata: metadata, postID: postID)
    }

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
        let supplied = VideoInput(canonicalID: id, url: url, title: title,
                                  duration: duration, width: width, height: height,
                                  frameRate: frameRate, fileSize: fileSize,
                                  metadata: metadata, postID: postID)
        // Preserve the legacy nonthrowing entry point. New callers should use inspect().
        self = (try? await VideoSource(url: url, title: title, postID: postID)
            .inspect(preserving: supplied)) ?? supplied
    }

    /// Inspects a URL once. Security-scoped access is balanced when available;
    /// ordinary readable file URLs do not require a security-scope grant.
    public init(from url: URL, postID: String? = nil) async throws {
        self = try await VideoSource(url: url, postID: postID).inspect()
    }
}
