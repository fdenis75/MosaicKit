import Foundation
import CoreGraphics

/// Encoding options forwarded to the FFmpeg process when `PreviewExportMode.ffmpeg` is active.
///
/// Use ``from(quality:format:)`` to derive sane defaults that mirror the quality
/// levels used by the SJS and native export paths, or construct directly for
/// fine-grained control.
public struct FFmpegEncodingOptions: Codable, Sendable, Hashable {

    // MARK: - Nested types

    /// Video codec passed to ffmpeg via `-c:v`.
    public enum VideoCodec: String, Codable, Sendable {
        case h264 = "libx264"
        case hevc = "libx265"
        case av1  = "libaom-av1"
        case copy = "copy"

        public var displayName: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC (H.265)"
            case .av1:  return "AV1"
            case .copy: return "Copy (passthrough)"
            }
        }
    }

    /// Audio codec passed to ffmpeg via `-c:a`.
    public enum AudioCodec: String, Codable, Sendable {
        case aac
        case mp3  = "libmp3lame"
        case opus = "libopus"
        case copy = "copy"

        public var displayName: String {
            switch self {
            case .aac:  return "AAC"
            case .mp3:  return "MP3"
            case .opus: return "Opus"
            case .copy: return "Copy (passthrough)"
            }
        }
    }

    /// Encoder speed/quality trade-off preset (`-preset` for x264/x265).
    /// Has no effect when `videoCodec` is `.copy` or `.av1`.
    public enum SpeedPreset: String, Codable, Sendable {
        case ultrafast, superfast, veryfast, faster, fast, medium, slow, veryslow
    }

    /// Maximum output resolution. The ffmpeg `scale` filter is applied only when
    /// the source is larger than the specified size (never upscales).
    public enum MaxResolution: String, Codable, Sendable {
        case _4K   = "3840:2160"
        case _1080p = "1920:1080"
        case _720p  = "1280:720"
        case sd     = "640:480"

        /// `scale` filter argument string that downscales to fit within this resolution while
        /// preserving aspect ratio. Never upscales; has no effect when the source is already smaller.
        /// Suitable for direct use as the value of the ffmpeg `-vf` option (no shell quoting needed
        /// since arguments are passed as an array, not via a shell).
        public var scaleFilter: String {
            "scale=\(width):\(height):force_original_aspect_ratio=decrease"
        }

        public var width: Int {
            switch self {
            case ._4K:    return 3840
            case ._1080p: return 1920
            case ._720p:  return 1280
            case .sd:     return 640
            }
        }

        public var height: Int {
            switch self {
            case ._4K:    return 2160
            case ._1080p: return 1080
            case ._720p:  return 720
            case .sd:     return 480
            }
        }

        public var cgSize: CGSize { CGSize(width: width, height: height) }
    }

    // MARK: - Properties

    /// Video codec. Default is `.hevc`.
    public var videoCodec: VideoCodec

    /// Constant Rate Factor for quality-based encoding (0–51 for x264/x265; lower = better).
    /// Mutually exclusive with `videoBitrate`; `crf` takes precedence when both are set.
    public var crf: Int?

    /// Target video bitrate (e.g. `"5M"`, `"2000k"`). Used only when `crf` is `nil`.
    public var videoBitrate: String?

    /// Encoder speed/quality preset. Default is `.medium`.
    public var speedPreset: SpeedPreset

    /// Maximum output resolution. `nil` preserves source resolution.
    public var maxResolution: MaxResolution?

    /// Audio codec. Default is `.aac`.
    public var audioCodec: AudioCodec

    /// Target audio bitrate (e.g. `"128k"`, `"192k"`). Default is `"128k"`.
    public var audioBitrate: String

    /// Additional raw ffmpeg arguments appended after all generated flags.
    /// These are passed as-is; no shell expansion is performed.
    public var extraArgs: [String]

    // MARK: - Initialization

    public init(
        videoCodec: VideoCodec = .hevc,
        crf: Int? = 22,
        videoBitrate: String? = nil,
        speedPreset: SpeedPreset = .medium,
        maxResolution: MaxResolution? = ._1080p,
        audioCodec: AudioCodec = .aac,
        audioBitrate: String = "128k",
        extraArgs: [String] = []
    ) {
        self.videoCodec = videoCodec
        self.crf = crf
        self.videoBitrate = videoBitrate
        self.speedPreset = speedPreset
        self.maxResolution = maxResolution
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.extraArgs = extraArgs
    }

    // MARK: - Factory

    /// Derive encoding options from a normalised `compressionQuality` value (0.0–1.0),
    /// mirroring the quality mapping used by the SJS export path.
    ///
    /// | Quality | Codec | CRF | Preset | Max res |
    /// |---------|-------|-----|--------|---------|
    /// | 1.0     | HEVC  | 18  | slow   | 4K      |
    /// | 0.75–0.9| H.264 | 20  | medium | 4K      |
    /// | 0.5–0.74| H.264 | 23  | fast   | 1080p   |
    /// | < 0.5   | H.264 | 28  | fast   | 720p    |
    public static func from(quality: Double, format: VideoFormat) -> FFmpegEncodingOptions {
        if quality >= 1.0 {
            return FFmpegEncodingOptions(
                videoCodec: .hevc,
                crf: 18,
                speedPreset: .slow,
                maxResolution: ._4K,
                audioCodec: .aac,
                audioBitrate: "192k"
            )
        } else if quality >= 0.75 {
            return FFmpegEncodingOptions(
                videoCodec: .h264,
                crf: 20,
                speedPreset: .medium,
                maxResolution: ._4K,
                audioCodec: .aac,
                audioBitrate: "128k"
            )
        } else if quality >= 0.5 {
            return FFmpegEncodingOptions(
                videoCodec: .h264,
                crf: 23,
                speedPreset: .fast,
                maxResolution: ._1080p,
                audioCodec: .aac,
                audioBitrate: "128k"
            )
        } else {
            return FFmpegEncodingOptions(
                videoCodec: .h264,
                crf: 28,
                speedPreset: .fast,
                maxResolution: ._720p,
                audioCodec: .aac,
                audioBitrate: "128k"
            )
        }
    }

    // MARK: - Argument assembly

    /// Build the ffmpeg argument list for encoding `inputURL` to `outputURL`.
    /// Passthrough input is assumed to already be at the correct container format.
    func buildArguments(inputURL: URL, outputURL: URL, includeAudio: Bool) -> [String] {
        var args: [String] = [
            "-i", inputURL.path,
            "-y"  // overwrite output without prompting
        ]

        // Video codec
        args += ["-c:v", videoCodec.rawValue]

        // Quality / bitrate (skip for copy)
        if videoCodec != .copy {
            if let crf {
                args += ["-crf", "\(crf)"]
            } else if let videoBitrate {
                args += ["-b:v", videoBitrate]
            }
            args += ["-preset", speedPreset.rawValue]
        }

        // Resolution filter (skip for copy)
        if videoCodec != .copy, let maxResolution {
            args += ["-vf", maxResolution.scaleFilter]
        }

        // Audio
        if includeAudio {
            args += ["-c:a", audioCodec.rawValue]
            if audioCodec != .copy {
                args += ["-b:a", audioBitrate]
            }
        } else {
            args += ["-an"]
        }

        // Extra user-supplied args
        args += extraArgs

        args.append(outputURL.path)
        return args
    }
}
