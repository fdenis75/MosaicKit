import AVFoundation
import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "com.mosaicKit", category: "ffmpeg-routing")

/// A source only ffmpeg can decode: what supplies its frames and extracts.
struct FFmpegSource: Sendable {
    /// The source the caller named. Output names and metadata come from it.
    let original: URL
    /// What ffmpeg reads: `original`, or a seekable copy of it.
    let input: URL
    let info: MediaInfo
    let settings: FFmpegFallback.Settings
}

/// How a source is read once any file it needs has been made.
enum PreparedSource {
    case asset(AVURLAsset)
    case ffmpeg(FFmpegSource)
}

/// Decides how each source is read when ``FFmpegFallback`` is enabled, and makes what that
/// route needs.
enum SourceRouter {
    struct Verdict: Sendable {
        let route: FFmpegFallback.Route
        /// Set for every route but `.native`.
        let info: MediaInfo?
        static let native = Verdict(route: .native, info: nil)
    }

    /// Verdicts per source and contents, so each file is probed once.
    private static let verdicts = Mutex<[String: Verdict]>([:])

    static func forgetVerdicts() {
        verdicts.withLock { $0.removeAll() }
    }

    private static func remember(_ verdict: Verdict, for url: URL) {
        let key = FFmpegCache.key(for: url)
        verdicts.withLock { cache in
            if cache.count >= 1024 { cache.removeAll() }
            cache[key] = verdict
        }
    }

    /// Containers AVFoundation is built around: probed by asking, not by decoding a frame.
    private static let appleExtensions: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp", "3g2"]

    /// Video codecs VideoToolbox decodes once they sit in an MP4.
    static let remuxableCodecs: Set<String> = ["h264", "hevc", "mpeg4", "mpeg2video", "prores", "av1"]

    /// Containers that may have no usable index, so that every seek reads from the start.
    private static let indexlessExtensions: Set<String> = ["avi", "divx", "flv", "mpg", "mpeg", "vob"]

    /// How `url` would be read. Never writes a file.
    static func detect(_ url: URL) async throws -> Verdict {
        #if os(macOS)
        // Playlists are never probed: AVFoundation streams them.
        guard let settings = FFmpegFallback.currentSettings, url.pathExtension.lowercased() != "m3u8" else {
            return .native
        }
        if let known = verdicts.withLock({ $0[FFmpegCache.key(for: url)] }) { return known }
        if try await decodesNatively(url) {
            remember(.native, for: url)
            return .native
        }
        let info: MediaInfo
        do {
            info = try await MediaInfo.probe(url, ffprobe: settings.ffprobeBinaryPath)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Neither can read it: the native reader reports its own error. Not remembered, so
            // a transient failure (network, permission) is retried.
            logger.notice("ffprobe can't read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .native
        }
        let route: FFmpegFallback.Route = remuxableCodecs.contains(info.videoCodec) ? .remuxed : .ffmpeg
        let verdict = Verdict(route: route, info: info)
        remember(verdict, for: url)
        logger.info("\(url.lastPathComponent, privacy: .public): route \(route.rawValue, privacy: .public) (\(info.videoCodec, privacy: .public))")
        return verdict
        #else
        return .native
        #endif
    }

    /// Whether AVFoundation can decode `url` itself. Outside Apple's containers this decodes one
    /// frame: some AVI files load tracks and a duration, then fail every decode (-11869).
    static func decodesNatively(_ url: URL) async throws -> Bool {
        let container = await RemoteVideoSupport.sourceContainer(for: url)
        let asset = RemoteVideoSupport.nativeAsset(url: url, options: [:], reduceReads: false, container: container)
        do {
            if appleExtensions.contains(url.pathExtension.lowercased()) {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
                return try await track.load(.isDecodable)
            }
            try await decodeOneFrame(of: asset)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A remote source also fails for network reasons, which are not a routing matter.
            return url.isFileURL ? false : !RemoteVideoSupport.isUnreadableMediaError(error)
        }
    }

    private static func decodeOneFrame(of asset: AVAsset) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        _ = try await generator.image(at: .zero)
    }

    /// Reads `url` by its route, remuxing or copying it first when needed.
    static func prepare(_ url: URL, options: [String: Any] = [:], reduceReads: Bool = false) async throws -> PreparedSource {
        #if os(macOS)
        if let settings = FFmpegFallback.currentSettings {
            var verdict = try await detect(url)
            if verdict.route == .remuxed {
                if let file = try await remux(url, audioCodec: verdict.info?.audioCodec, settings: settings) {
                    return .asset(AVURLAsset(url: file, options: options))
                }
                // The codec didn't decode after all (for example AV1 on a Mac without the decoder).
                verdict = Verdict(route: .ffmpeg, info: verdict.info)
                remember(verdict, for: url)
            }
            if verdict.route == .ffmpeg, let info = verdict.info {
                let input = try await seekableInput(for: url, info: info, settings: settings)
                return .ffmpeg(FFmpegSource(original: url, input: input, info: info, settings: settings))
            }
        }
        #endif
        let container = await RemoteVideoSupport.sourceContainer(for: url)
        return .asset(RemoteVideoSupport.nativeAsset(url: url, options: options, reduceReads: reduceReads, container: container))
    }

    #if os(macOS)
    /// One ffmpeg attempt: its stream and codec arguments.
    struct Attempt: Sendable {
        let label: String
        let arguments: [String]
    }

    private static let videoAndAudio = ["-map", "0:V:0", "-map", "0:a:0?"]

    /// Audio codecs AVFoundation plays and composes out of an MP4. Others copy without error and
    /// then go missing from previews (MP3 from AVI does), so they are re-encoded.
    private static let copyableAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "alac"]

    /// `hvc1` first: AVFoundation decodes HEVC in MP4 only with that sample-entry tag, and ffmpeg
    /// refuses the tag for any other codec. Audio is dropped only as the last resort.
    static func remuxAttempts(audioCodec: String?) -> [Attempt] {
        let copiesAudio = audioCodec.map(copyableAudioCodecs.contains) ?? true
        let audio = copiesAudio ? ["-c", "copy"] : ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
        return [
            Attempt(label: "hvc1", arguments: videoAndAudio + audio + ["-tag:v", "hvc1"]),
            Attempt(label: "copy", arguments: videoAndAudio + audio),
            Attempt(label: "video only", arguments: ["-map", "0:V:0", "-c", "copy", "-an"]),
        ]
    }

    /// The MP4 copy of `url`, made on first use. `nil` when AVFoundation can't decode any copy.
    private static func remux(_ url: URL, audioCodec: String?, settings: FFmpegFallback.Settings) async throws -> URL? {
        let destination = FFmpegCache.file(for: url, variant: "remux", extension: "mp4", in: settings.cacheDirectory)
        if let existing = FFmpegCache.existing(destination) { return existing }
        do {
            return try await RemuxJobs.shared.result(for: destination) {
                try await copyStreams(of: url, to: destination, attempts: remuxAttempts(audioCodec: audioCodec), format: "mp4",
                                      verify: true, settings: settings)
            }
        } catch is UndecodableCopy {
            return nil
        }
    }

    private struct UndecodableCopy: Error {}

    /// The file ffmpeg seeks in for `url`: the source itself, or, when seeking near its end is
    /// slow (a missing or broken index), a Matroska copy of its streams.
    private static func seekableInput(for url: URL, info: MediaInfo, settings: FFmpegFallback.Settings) async throws -> URL {
        guard url.isFileURL, indexlessExtensions.contains(url.pathExtension.lowercased()) else { return url }
        let destination = FFmpegCache.file(for: url, variant: "seekable", extension: "mkv", in: settings.cacheDirectory)
        if let existing = FFmpegCache.existing(destination) { return existing }
        let early = try await seekTime(url, at: 0, settings: settings)
        let late = try await seekTime(url, at: info.duration * 0.9, settings: settings)
        guard late - early > .seconds(1) else { return url }
        logger.notice("Seeking is slow in \(url.lastPathComponent, privacy: .public): copying it to Matroska first")
        let attempts = [
            Attempt(label: "mkv", arguments: videoAndAudio + ["-c", "copy"]),
            Attempt(label: "mkv, video only", arguments: ["-map", "0:V:0", "-c", "copy", "-an"]),
        ]
        return try await RemuxJobs.shared.result(for: destination) {
            try await copyStreams(of: url, to: destination, attempts: attempts, format: "matroska",
                                  verify: false, settings: settings)
        }
    }

    /// How long decoding one frame at `time` takes.
    private static func seekTime(_ url: URL, at time: TimeInterval, settings: FFmpegFallback.Settings) async throws -> Duration {
        let arguments = ["-nostdin", "-v", "error", "-ss", String(format: "%.3f", time)]
            + FFmpegRunner.inputArguments(for: url) + ["-map", "0:V:0", "-frames:v", "1", "-f", "null", "-"]
        return try await ContinuousClock().measure {
            _ = try await FFmpegRunner.run(settings.ffmpegBinaryPath, arguments, timeout: 300)
        }
    }

    /// Writes the streams of `source` to `destination` without re-encoding the video.
    private static func copyStreams(of source: URL, to destination: URL, attempts: [Attempt], format: String,
                                    verify: Bool, settings: FFmpegFallback.Settings) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let partial = FFmpegCache.partial(of: destination)
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
        FFmpegCache.evict(in: settings.cacheDirectory, toFit: size ?? 0, maximumBytes: settings.maximumCacheBytes)

        var lastError: (any Error)?
        var undecodable = false
        for attempt in attempts {
            try Task.checkCancellation()
            logger.info("Copying \(source.lastPathComponent, privacy: .public) (\(attempt.label, privacy: .public))")
            var arguments = ["-nostdin", "-hide_banner", "-y"]
            if !source.isFileURL {
                arguments += ["-reconnect", "1", "-reconnect_on_network_error", "1", "-reconnect_delay_max", "10"]
            }
            arguments += FFmpegRunner.inputArguments(for: source) + attempt.arguments + ["-f", format, partial.path]
            do {
                try await FFmpegEncoder.runFFmpeg(
                    binaryPath: settings.ffmpegBinaryPath, arguments: arguments, totalDuration: 0,
                    progressHandler: { _, _ in }, cancellationCheck: { false }
                )
            } catch PreviewError.cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PreviewError {
                // Only an ffmpeg error exit is worth another attempt (a refused tag or codec
                // fails at once). A stall or the time limit would only read the source again.
                guard case .ffmpegEncodingFailed = error else { throw VideoError.processingFailed(source, error) }
                lastError = error
                continue
            } catch {
                throw VideoError.processingFailed(source, error)
            }
            if verify {
                do {
                    try await decodeOneFrame(of: AVURLAsset(url: partial))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    undecodable = true
                    continue
                }
            }
            do {
                try FileManager.default.moveItem(at: partial, to: destination)
            } catch {
                throw VideoError.processingFailed(source, error)
            }
            return destination
        }
        if undecodable { throw UndecodableCopy() }
        throw VideoError.processingFailed(source, lastError ?? MosaicError.processingFailed("ffmpeg copy failed"))
    }
    #endif
}
