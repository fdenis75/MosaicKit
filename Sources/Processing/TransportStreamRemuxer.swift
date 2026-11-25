import AVFoundation
import CryptoKit
import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "com.mosaicKit", category: "ts-remux")

/// Reads MPEG transport streams that AVFoundation can't, by remuxing them to MP4 with ffmpeg
/// (macOS only, opt-in; I-38).
///
/// AVFoundation's transport-stream demuxer reads H.264 and MPEG-2 video only. HEVC, AV1 or
/// MPEG-4 Part 2 in a `.ts` file fails with ``VideoError/unsupportedCodec(_:_:)``, although
/// VideoToolbox decodes the same HEVC once it sits in an MP4 container. When enabled, such a
/// source is copied into an MP4 file (`ffmpeg -c copy`: no re-encode, the video and first audio
/// stream only) in a cache folder, and every reader of the source (inspection, mosaics,
/// animations, previews, thumbnails) opens that file instead. Output names, metadata and the
/// file size still come from the source URL.
///
/// - A transport stream AVFoundation reads itself (H.264, MPEG-2) is never remuxed.
/// - A remote source is downloaded in full by ffmpeg, once: the MP4 is kept in the cache folder,
///   keyed by the source URL, and reused by later calls and later runs until it is evicted.
///   ``MosaicConfiguration/reduceSourceReads`` doesn't apply to it.
/// - Not available on iOS and Mac Catalyst (no external processes): ``enable(ffmpegBinaryPath:cacheDirectory:maximumCacheBytes:)``
///   throws there, and transport streams keep failing with the error above.
///
/// ```swift
/// try TransportStreamRemuxer.enable(ffmpegBinaryPath: "/opt/homebrew/bin/ffmpeg")
/// let input = try await VideoInput(from: hevcTransportStreamURL)   // remuxed here, once
/// let mosaic = try await MetalMosaicGenerator().generate(for: input, config: config)
/// ```
public enum TransportStreamRemuxer {
    /// Default cache size: when the cache folder grows past it, the least recently used files
    /// are deleted.
    public static let defaultMaximumCacheBytes: Int64 = 20 * 1024 * 1024 * 1024

    /// The default cache folder, under the temporary directory.
    public static var defaultCacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitRemux", isDirectory: true)
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
        let cacheDirectory: URL
        let maximumCacheBytes: Int64
    }

    private static let settings = Mutex<Settings?>(nil)

    /// Whether ``enable(ffmpegBinaryPath:cacheDirectory:maximumCacheBytes:)`` was called (and
    /// not undone by ``disable()``).
    public static var isEnabled: Bool { settings.withLock { $0 != nil } }

    /// Turns remuxing on for the process.
    ///
    /// - Parameters:
    ///   - ffmpegBinaryPath: An executable `ffmpeg`, for example `/opt/homebrew/bin/ffmpeg`.
    ///   - cacheDirectory: Where remuxed files are kept; created if needed. Default
    ///     ``defaultCacheDirectory``.
    ///   - maximumCacheBytes: The cache size past which the least recently used files are
    ///     deleted. Default ``defaultMaximumCacheBytes`` (20 GB).
    /// - Throws: ``MosaicError/invalidConfiguration(_:)`` on iOS and Mac Catalyst, for a path that
    ///   isn't an executable file, or for a cache folder that can't be created.
    public static func enable(
        ffmpegBinaryPath: String,
        cacheDirectory: URL? = nil,
        maximumCacheBytes: Int64 = defaultMaximumCacheBytes
    ) throws {
        #if os(macOS)
        do {
            try FFmpegEncoder.validate(binaryPath: ffmpegBinaryPath)
        } catch {
            throw MosaicError.invalidConfiguration("ffmpeg not found or not executable at \(ffmpegBinaryPath)")
        }
        guard maximumCacheBytes > 0 else {
            throw MosaicError.invalidConfiguration("maximumCacheBytes must be positive")
        }
        let directory = cacheDirectory ?? defaultCacheDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MosaicError.invalidConfiguration("Can't create the remux cache folder \(directory.path): \(error.localizedDescription)")
        }
        settings.withLock {
            $0 = Settings(ffmpegBinaryPath: ffmpegBinaryPath, cacheDirectory: directory, maximumCacheBytes: maximumCacheBytes)
        }
        RemoteVideoSupport.forgetNativeReadability()
        #else
        throw MosaicError.invalidConfiguration("Transport-stream remuxing needs ffmpeg, which is only available on macOS")
        #endif
    }

    /// Turns remuxing off. Files already in the cache stay there (see ``clearCache()``), but
    /// aren't used until remuxing is enabled again.
    public static func disable() {
        settings.withLock { $0 = nil }
    }

    /// Deletes every remuxed file in the cache folder. Does nothing when remuxing is off.
    public static func clearCache() throws {
        guard let directory = settings.withLock({ $0?.cacheDirectory }) else { return }
        for file in try cachedFiles(in: directory) {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: Internal

    static var currentSettings: Settings? { settings.withLock { $0 } }

    /// The cache file of `source`: the first 16 hex digits of the SHA-256 of its URL.
    static func cacheFile(for source: URL, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).mp4")
    }

    /// The remuxed file of `source`, if remuxing is on and one is in the cache. Touches it, so
    /// eviction keeps recently used files.
    static func existingRemux(of source: URL) -> URL? {
        guard let directory = currentSettings?.cacheDirectory else { return nil }
        let file = cacheFile(for: source, in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    /// Remuxes `source` into the cache, or waits for the remux already running for it.
    ///
    /// - Throws: `CancellationError` when cancelled (a cancel also stops a remux shared with
    ///   other callers), ``VideoError/processingFailed(_:_:)`` when ffmpeg fails.
    static func remux(_ source: URL) async throws -> URL {
        #if os(macOS)
        guard let settings = currentSettings else {
            throw MosaicError.invalidConfiguration("Transport-stream remuxing is not enabled")
        }
        if let existing = existingRemux(of: source) { return existing }
        let task = await RemuxJobs.shared.task(for: source) {
            try await performRemux(source, settings: settings)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        #else
        throw MosaicError.invalidConfiguration("Transport-stream remuxing needs ffmpeg, which is only available on macOS")
        #endif
    }

    #if os(macOS)
    /// One ffmpeg attempt: its extra output arguments.
    struct Attempt: Sendable {
        let label: String
        let arguments: [String]
    }

    /// `hvc1` first: AVFoundation decodes HEVC in MP4 only with that sample-entry tag (ffmpeg
    /// writes `hev1` by default), and ffmpeg refuses the tag for any other codec, so the
    /// second attempt drops it. The last one also drops the audio, in case its codec can't go
    /// into MP4 or AVFoundation refuses it.
    static let attempts: [Attempt] = [
        Attempt(label: "hvc1", arguments: ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-tag:v", "hvc1"]),
        Attempt(label: "copy", arguments: ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]),
        Attempt(label: "video only", arguments: ["-map", "0:v:0", "-c", "copy", "-an"]),
    ]

    /// The full ffmpeg arguments that remux `source` to `output` with `attempt`.
    static func arguments(source: URL, output: URL, attempt: Attempt) -> [String] {
        var input = ["-nostdin", "-hide_banner", "-y"]
        if !source.isFileURL {
            input += ["-reconnect", "1", "-reconnect_on_network_error", "1", "-reconnect_delay_max", "10"]
        }
        input += ["-i", source.isFileURL ? source.path : source.absoluteString]
        return input + attempt.arguments + ["-f", "mp4", output.path]
    }

    private static func performRemux(_ source: URL, settings: Settings) async throws -> URL {
        let destination = cacheFile(for: source, in: settings.cacheDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let partial = destination.deletingPathExtension().appendingPathExtension("part.mp4")
        defer { try? FileManager.default.removeItem(at: partial) }

        let size: Int64? = source.isFileURL
            ? (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? nil
            : await RemoteVideoSupport.contentLength(of: source)
        do {
            let neededMB = Int((size ?? 0) / (1024 * 1024)) + 500
            try FFmpegEncoder.checkTempDiskSpace(at: settings.cacheDirectory, minimumMB: neededMB)
        } catch {
            throw VideoError.processingFailed(source, error)
        }
        evict(in: settings.cacheDirectory, toFit: size ?? 0, maximumBytes: settings.maximumCacheBytes)

        let host = source.isFileURL ? source.lastPathComponent : (source.host() ?? "?")
        var lastError: (any Error)?
        for attempt in attempts {
            try Task.checkCancellation()
            logger.info("Remuxing transport stream from \(host, privacy: .public) (\(attempt.label, privacy: .public))")
            do {
                try await FFmpegEncoder.runFFmpeg(
                    binaryPath: settings.ffmpegBinaryPath,
                    arguments: arguments(source: source, output: partial, attempt: attempt),
                    totalDuration: 0,
                    progressHandler: { _, _ in },
                    cancellationCheck: { false }
                )
            } catch PreviewError.cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                logger.notice("Remux attempt \(attempt.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if try await hasReadableVideo(partial) {
                try FileManager.default.moveItem(at: partial, to: destination)
                logger.info("Remuxed \(host, privacy: .public) to \(destination.lastPathComponent, privacy: .public)")
                return destination
            }
            lastError = MosaicError.invalidVideo("AVFoundation can't read the remuxed file (\(attempt.label))")
        }
        throw VideoError.processingFailed(source, lastError ?? MosaicError.processingFailed("ffmpeg remux failed"))
    }

    /// Whether AVFoundation reads a video track and a duration from `file`.
    static func hasReadableVideo(_ file: URL) async throws -> Bool {
        let asset = AVURLAsset(url: file)
        do {
            let (tracks, duration) = try await asset.load(.tracks, .duration)
            return tracks.contains { $0.mediaType == .video } && duration.seconds.isFinite && duration.seconds > 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }
    #endif

    /// The remuxed files in `directory`, oldest use first.
    static func cachedFiles(in directory: URL) throws -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        return files.filter { $0.pathExtension == "mp4" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.used < $1.used }
    }

    /// Deletes the least recently used files until `incoming` more bytes fit in `maximumBytes`.
    static func evict(in directory: URL, toFit incoming: Int64, maximumBytes: Int64) {
        guard var files = try? cachedFiles(in: directory) else { return }
        var total = files.reduce(0) { $0 + $1.size }
        while total + incoming > maximumBytes, !files.isEmpty {
            let oldest = files.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            logger.info("Evicted \(oldest.url.lastPathComponent, privacy: .public) from the remux cache")
        }
    }
}

/// The remux running for each source, so concurrent readers share one ffmpeg run.
actor RemuxJobs {
    static let shared = RemuxJobs()
    private var running: [URL: Task<URL, any Error>] = [:]

    func task(for source: URL, _ work: @escaping @Sendable () async throws -> URL) -> Task<URL, any Error> {
        if let task = running[source] { return task }
        // The task runs on this actor (it uses `self`), so it can't start, nor finish, before
        // it is stored below.
        let task = Task<URL, any Error> {
            defer { self.running[source] = nil }
            return try await work()
        }
        running[source] = task
        return task
    }
}
