import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.mosaicKit", category: "ffmpeg-extracts")

/// The preview extracts of a source only ffmpeg decodes, encoded to MP4 and joined into a
/// composition the preview pipeline reads like any other source.
struct FFmpegExtracts {
    /// The extracts back to back.
    let asset: AVMutableComposition
    /// Where each extract sits in `asset`, in the order requested.
    let ranges: [(start: CMTime, duration: CMTime)]

    #if os(macOS)
    private static let concurrentEncodes = 3

    /// Encodes each of `extracts` (times in the source) into `directory` and joins them. A file
    /// already there is reused. The files must outlive the composition.
    static func make(
        from source: FFmpegSource,
        extracts: [(start: CMTime, duration: CMTime)],
        includeAudio: Bool,
        in directory: URL,
        progress: @Sendable (Int) -> Void
    ) async throws -> FFmpegExtracts {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = extracts.map { extract in
            FFmpegCache.file(
                for: source.original,
                variant: "extract-\(extract.start.seconds)-\(extract.duration.seconds)-\(includeAudio)",
                extension: "mp4", in: directory)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var done = 0
            func launch() {
                let extract = extracts[next]
                let file = files[next]
                next += 1
                group.addTask {
                    try await encode(source, start: extract.start.seconds, duration: extract.duration.seconds,
                                     includeAudio: includeAudio, to: file)
                }
            }
            while next < min(concurrentEncodes, extracts.count) { launch() }
            while try await group.next() != nil {
                done += 1
                progress(done)
                if next < extracts.count { launch() }
            }
        }
        return try await join(files, extracts: extracts, includeAudio: includeAudio)
    }

    private static func encode(_ source: FFmpegSource, start: Double, duration: Double,
                               includeAudio: Bool, to file: URL) async throws {
        if FFmpegCache.existing(file) != nil { return }
        let partial = FFmpegCache.partial(of: file)
        defer { try? FileManager.default.removeItem(at: partial) }

        let info = source.info
        // Even dimensions; H.264 stops at 4096 × 2304, HEVC carries on.
        let width = info.width + info.width % 2
        let height = info.height + info.height % 2
        let useHEVC = width > 4096 || height > 2304
        // Generous: this is an intermediate that the preview export encodes again.
        let bitrate = Int(min(max(Double(width * height) * min(info.frameRate ?? 30, 60) * 0.2, 4e6), 80e6))
        var filters: [String] = []
        if info.isInterlaced { filters.append("yadif=mode=send_frame") }
        filters.append("scale=trunc(iw*sar/2)*2:trunc(ih/2)*2,setsar=1")
        var video = ["-map", "0:V:0", "-vf", filters.joined(separator: ","),
                     "-c:v", useHEVC ? "hevc_videotoolbox" : "h264_videotoolbox",
                     "-allow_sw", "1", "-b:v", String(bitrate), "-pix_fmt", "yuv420p"]
        if useHEVC { video += ["-tag:v", "hvc1"] }
        let audio = ["-map", "0:a:0?", "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        let input = ["-nostdin", "-hide_banner", "-v", "error", "-y", "-ss", String(format: "%.3f", start)]
            + FFmpegRunner.inputArguments(for: source.input) + ["-t", String(format: "%.3f", duration)]

        // Audio that can't be decoded is dropped rather than failing the preview, and said so.
        let attempts = includeAudio && info.hasAudio ? [video + audio, video + ["-an"]] : [video + ["-an"]]
        var lastError = ""
        for (index, attempt) in attempts.enumerated() {
            let output = try await FFmpegRunner.run(
                source.settings.ffmpegBinaryPath,
                input + attempt + ["-movflags", "+faststart", "-f", "mp4", partial.path],
                timeout: 120 + duration * 30)
            if output.status == 0 {
                if index > 0 {
                    logger.warning("Audio of \(source.original.lastPathComponent, privacy: .public) can't be encoded at \(start, privacy: .public) s: extract has none")
                }
                try FFmpegCache.publish(partial, as: file)
                return
            }
            lastError = String(output.stderr.suffix(300))
        }
        throw PreviewError.extractionFailed("ffmpeg can't encode the extract at \(String(format: "%.2f", start)) s: \(lastError)", nil)
    }

    private static func join(_ files: [URL], extracts: [(start: CMTime, duration: CMTime)],
                             includeAudio: Bool) async throws -> FFmpegExtracts {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PreviewError.compositionFailed("Failed to create composition video track", nil)
        }
        var audioTrack: AVMutableCompositionTrack?
        var ranges: [(start: CMTime, duration: CMTime)] = []
        var cursor = CMTime.zero
        for (file, extract) in zip(files, extracts) {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw PreviewError.noVideoTracks
            }
            // A frame boundary can leave the file a little shorter than asked.
            let length = CMTimeMinimum(try await video.load(.timeRange).duration, extract.duration)
            guard length.seconds > 0 else {
                throw PreviewError.extractionFailed("Empty extract at \(String(format: "%.2f", extract.start.seconds)) s", nil)
            }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: video, at: cursor)
            if includeAudio, let audio = try await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let available = try await audio.load(.timeRange).duration
                try audioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(available, length)),
                                                of: audio, at: cursor)
            }
            ranges.append((cursor, length))
            cursor = CMTimeAdd(cursor, length)
        }
        // Extracts made for a player live in the cache: keep them while the composition does.
        files.forEach { FFmpegCache.hold($0, for: composition) }
        return FFmpegExtracts(asset: composition, ranges: ranges)
    }
    #endif
}
