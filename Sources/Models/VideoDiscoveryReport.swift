import Foundation

/// A file found by discovery that could not be inspected (unreadable, no video track, an
/// undecodable codec on this platform, invalid geometry, ...).
public struct VideoDiscoveryFailure: Sendable {
    /// The file that failed.
    public let url: URL
    /// Why inspection failed, typically a ``MosaicError`` or ``VideoError``.
    public let error: any Error

    public init(url: URL, error: any Error) {
        self.url = url
        self.error = error
    }
}

/// The outcome of ``discoverVideosReportingFailures(in:recursive:metadataConcurrency:)``: the inputs
/// that were inspected, and the files that could not be.
public struct VideoDiscoveryReport: Sendable {
    /// Successfully inspected videos, in filename order.
    public let videos: [VideoInput]
    /// Files that failed inspection, in filename order.
    public let failures: [VideoDiscoveryFailure]

    public init(videos: [VideoInput], failures: [VideoDiscoveryFailure]) {
        self.videos = videos
        self.failures = failures
    }
}
