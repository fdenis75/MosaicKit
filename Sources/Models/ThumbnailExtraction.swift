import Foundation
import CoreGraphics

/// How extracted thumbnails are spread over a video.
public enum ThumbnailSampling: String, Codable, Sendable, CaseIterable {
    /// Evenly spaced over 5…95 % of the duration, one frame at the center of each of `count`
    /// equal slices. A strip read left to right shows equal time steps.
    case uniform
    /// The mosaic policy: 20 % of the frames over the first third, 60 % over the middle third and
    /// 20 % over the last (within 5…95 % of the duration).
    case weighted
}

/// Options for ``MetalMosaicGenerator/extractThumbnails(for:options:)`` and
/// ``MetalMosaicGenerator/exportThumbnails(for:options:to:)``.
public struct ThumbnailExtractionOptions: Codable, Sendable, Hashable {
    /// The largest accepted ``count``.
    public static let maximumCount = 10_000

    /// Number of thumbnails to extract, 1…``maximumCount``.
    public var count: Int
    /// The box each frame is scaled to fit, keeping its aspect ratio; `nil` keeps the video's
    /// display size. Frames are never scaled up.
    public var maximumSize: CGSize?
    /// How the frames are spread over the video.
    public var sampling: ThumbnailSampling
    /// `true` decodes the exact requested times (slower); `false` accepts the nearest frame within
    /// one second, usually a keyframe.
    public var accurate: Bool
    /// The file format used by ``MetalMosaicGenerator/exportThumbnails(for:options:to:)``. `.webp`
    /// needs `MosaicKitWebP.register()`. Ignored by in-memory extraction.
    public var format: OutputFormat
    /// Lossy quality (0…1) for `.jpeg`, `.heif` and `.webp` files.
    public var compressionQuality: Double

    public init(
        count: Int = 10,
        maximumSize: CGSize? = nil,
        sampling: ThumbnailSampling = .uniform,
        accurate: Bool = false,
        format: OutputFormat = .jpeg,
        compressionQuality: Double = 0.8
    ) {
        self.count = count
        self.maximumSize = maximumSize
        self.sampling = sampling
        self.accurate = accurate
        self.format = format
        self.compressionQuality = compressionQuality
    }

    private enum CodingKeys: String, CodingKey {
        case count, maximumSize, sampling, accurate, format, compressionQuality
    }

    /// Every key is optional and falls back to the `init` default, so payloads saved before a key
    /// existed keep decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThumbnailExtractionOptions()
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? defaults.count
        maximumSize = try container.decodeIfPresent(CGSize.self, forKey: .maximumSize)
        sampling = try container.decodeIfPresent(ThumbnailSampling.self, forKey: .sampling) ?? defaults.sampling
        accurate = try container.decodeIfPresent(Bool.self, forKey: .accurate) ?? defaults.accurate
        format = try container.decodeIfPresent(OutputFormat.self, forKey: .format) ?? defaults.format
        compressionQuality = try container.decodeIfPresent(Double.self, forKey: .compressionQuality)
            ?? defaults.compressionQuality
    }
}

/// One frame extracted by ``MetalMosaicGenerator/extractThumbnails(for:options:)``.
public struct VideoThumbnail: Sendable {
    /// Position in temporal order, from 0.
    public let index: Int
    /// The time of the decoded frame, in seconds from the start of the video.
    public let time: TimeInterval
    /// The decoded frame, oriented as the video displays it.
    public let image: CGImage

    public init(index: Int, time: TimeInterval, image: CGImage) {
        self.index = index
        self.time = time
        self.image = image
    }
}

/// The files written by ``MetalMosaicGenerator/exportThumbnails(for:options:to:)``.
public struct ThumbnailExport: Sendable, Hashable {
    /// One written thumbnail file.
    public struct File: Sendable, Hashable {
        /// Position in temporal order, from 0.
        public let index: Int
        /// The time of the decoded frame, in seconds from the start of the video.
        public let time: TimeInterval
        /// The file's location inside ``ThumbnailExport/directory``.
        public let url: URL
    }

    /// The directory holding the files. When MosaicKit created it under the temporary directory,
    /// the caller owns it and should remove it when done.
    public let directory: URL
    /// The files, in temporal order.
    public let files: [File]
}
