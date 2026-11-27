import Foundation
import Synchronization

/// Lets MosaicKit read sources AVFoundation can't (AVI, WMV, FLV, MKV, WebM and similar) with an
/// external ffmpeg (macOS only, opt-in).
///
/// AVFoundation stays the default path. Nothing changes until ``enable(ffmpegBinaryPath:ffprobeBinaryPath:cacheDirectory:maximumCacheBytes:)``
/// is called.
public enum FFmpegFallback {
    /// How a source is read.
    public enum Route: String, Sendable {
        /// AVFoundation reads it by itself.
        case native
        /// The streams are decodable but the container isn't: copied into MP4, never re-encoded.
        case remuxed
        /// The codec isn't decodable: ffmpeg supplies frames and segments.
        case ffmpeg
    }

    /// Default cache size.
    public static let defaultMaximumCacheBytes: Int64 = 20 * 1024 * 1024 * 1024

    /// The default cache folder, under the temporary directory.
    public static var defaultCacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitFFmpegCache", isDirectory: true)
    }

    /// Whether this platform can run ffmpeg (macOS only).
    public static var isSupported: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    struct Settings: Sendable {
        let ffmpegBinaryPath: String
        let ffprobeBinaryPath: String
        let cacheDirectory: URL
        let maximumCacheBytes: Int64
    }

    private static let settings = Mutex<Settings?>(nil)

    static var currentSettings: Settings? { settings.withLock { $0 } }

    /// Whether the fallback is on.
    public static var isEnabled: Bool { currentSettings != nil }

    /// Turns the fallback on for the process.
    ///
    /// - Parameters:
    ///   - ffmpegBinaryPath: An executable `ffmpeg`.
    ///   - ffprobeBinaryPath: An executable `ffprobe`. Default: the one next to `ffmpeg`.
    ///   - cacheDirectory: Where intermediate files are kept. Default ``defaultCacheDirectory``.
    ///   - maximumCacheBytes: The cache size past which the least recently used files are deleted.
    /// - Throws: ``MosaicError/invalidConfiguration(_:)`` on iOS and Mac Catalyst, for a binary
    ///   that isn't executable, or for a cache folder that can't be created.
    public static func enable(
        ffmpegBinaryPath: String,
        ffprobeBinaryPath: String? = nil,
        cacheDirectory: URL? = nil,
        maximumCacheBytes: Int64 = defaultMaximumCacheBytes
    ) throws {
        #if os(macOS)
        let ffprobe = ffprobeBinaryPath
            ?? URL(fileURLWithPath: ffmpegBinaryPath).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        for binary in [ffmpegBinaryPath, ffprobe] {
            do {
                try FFmpegEncoder.validate(binaryPath: binary)
            } catch {
                throw MosaicError.invalidConfiguration("Not found or not executable: \(binary)")
            }
        }
        guard maximumCacheBytes > 0 else {
            throw MosaicError.invalidConfiguration("maximumCacheBytes must be positive")
        }
        let directory = cacheDirectory ?? defaultCacheDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MosaicError.invalidConfiguration("Can't create the cache folder \(directory.path): \(error.localizedDescription)")
        }
        SourceRouter.forgetVerdicts()
        settings.withLock {
            $0 = Settings(ffmpegBinaryPath: ffmpegBinaryPath, ffprobeBinaryPath: ffprobe,
                          cacheDirectory: directory, maximumCacheBytes: maximumCacheBytes)
        }
        #else
        throw MosaicError.invalidConfiguration("The ffmpeg fallback is only available on macOS")
        #endif
    }

    /// Turns the fallback off. Cached files stay until ``clearCache()``.
    public static func disable() {
        settings.withLock { $0 = nil }
        SourceRouter.forgetVerdicts()
    }

    /// Deletes every file in the cache folder. Does nothing when the fallback is off.
    public static func clearCache() throws {
        guard let directory = currentSettings?.cacheDirectory else { return }
        try FFmpegCache.clear(directory)
    }

    /// How `url` would be read. Never writes a file. Returns ``Route/native`` without probing when
    /// the fallback is off.
    public static func route(for url: URL) async throws -> Route {
        try await SourceRouter.detect(url).route
    }
}
