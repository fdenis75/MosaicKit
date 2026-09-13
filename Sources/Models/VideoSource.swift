import Foundation

/// A lightweight source reference. Construction never reads the file or loads an asset.
public struct VideoSource: Codable, Hashable, Sendable {
    public let url: URL
    public let title: String?
    public let postID: String?

    public init(url: URL, title: String? = nil, postID: String? = nil) {
        self.url = url
        self.title = title
        self.postID = postID
    }

    /// Loads metadata once and validates that the source contains usable video.
    public func inspect(id: UUID = UUID()) async throws -> VideoInput {
        try await inspect(preserving: VideoInput(canonicalID: id, url: url, title: title, postID: postID))
    }

    /// Loads missing metadata while retaining every explicitly supplied value and custom field.
    public func inspect(preserving supplied: VideoInput) async throws -> VideoInput {
        try Task.checkCancellation()
        guard supplied.url == url else {
            throw MosaicError.invalidVideo("Supplied metadata belongs to a different source URL")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try await VideoMetadataExtractor().extractMetadataValues(from: url)
        try Task.checkCancellation()
        let input = VideoInput(
            canonicalID: supplied.id, url: url, title: supplied.title,
            duration: supplied.duration ?? values.duration,
            width: supplied.width ?? values.width, height: supplied.height ?? values.height,
            frameRate: supplied.frameRate ?? values.frameRate,
            fileSize: supplied.fileSize ?? values.fileSize,
            metadata: VideoMetadata(codec: supplied.metadata.codec ?? values.videoCodec,
                                    bitrate: supplied.metadata.bitrate ?? values.bitrate,
                                    custom: supplied.metadata.custom),
            postID: supplied.postID ?? postID
        )
        try input.validate()
        return input
    }
}

extension VideoInput {
    /// Validates canonical geometry/timing before numeric conversion or allocation.
    public func validate() throws {
        guard let duration, duration.isFinite, duration > 0,
              let width, width.isFinite, width > 0, width < Double(Int.max),
              let height, height.isFinite, height > 0, height < Double(Int.max) else {
            throw MosaicError.invalidVideo("Duration and video dimensions must be finite and positive")
        }
        if let frameRate, !frameRate.isFinite || frameRate <= 0 {
            throw MosaicError.invalidVideo("Frame rate must be finite and positive when provided")
        }
        if let fileSize, fileSize < 0 {
            throw MosaicError.invalidVideo("File size cannot be negative")
        }
    }
}
