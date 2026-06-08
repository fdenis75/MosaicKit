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
        case h264             = "libx264"
        case hevc             = "libx265"
        case av1              = "libaom-av1"
        case copy             = "copy"
        /// Apple VideoToolbox hardware HEVC encoder.
        /// Fastest option on Apple Silicon / Intel Macs; ignores `-preset` and `-crf`.
        /// `SpeedPreset` is translated to `-realtime` + `-q:v` automatically.
        case hevcVideoToolbox = "hevc_videotoolbox"
        /// Apple VideoToolbox hardware H.264 encoder.
        /// Same speed characteristics as `hevcVideoToolbox` but wider player compatibility.
        case h264VideoToolbox = "h264_videotoolbox"

        public var displayName: String {
            switch self {
            case .h264:             return "H.264 (libx264)"
            case .hevc:             return "HEVC (libx265)"
            case .av1:              return "AV1"
            case .copy:             return "Copy (passthrough)"
            case .hevcVideoToolbox: return "HEVC (VideoToolbox)"
            case .h264VideoToolbox: return "H.264 (VideoToolbox)"
            }
        }

        /// Short tag used in filenames and test combo names.
        public var tag: String {
            switch self {
            case .h264:             return "h264"
            case .hevc:             return "hevc"
            case .av1:              return "av1"
            case .copy:             return "copy"
            case .hevcVideoToolbox: return "hevc_vt"
            case .h264VideoToolbox: return "h264_vt"
            }
        }

        /// `true` for hardware VideoToolbox encoders that do not support `-preset` or `-crf`.
        public var isVideoToolbox: Bool {
            self == .hevcVideoToolbox || self == .h264VideoToolbox
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

    /// Encoder speed/quality trade-off selector.
    ///
    /// - For **software codecs** (`h264`, `hevc`, `av1`): passed verbatim as `-preset`.
    /// - For **VideoToolbox codecs** (`hevcVideoToolbox`, `h264VideoToolbox`): translated
    ///   to `-realtime 1/0` (real-time encoding hint) plus a `-q:v` quality level
    ///   (VideoToolbox scale 1–100; higher = better quality / larger file).
    ///   `-preset` is never emitted for hardware encoders.
    ///
    /// VideoToolbox mapping:
    ///
    /// | Preset     | -realtime | -q:v | Intent                     |
    /// |:-----------|:---------:|:----:|:---------------------------|
    /// | ultrafast  | 1         | 40   | Maximum throughput          |
    /// | superfast  | 1         | 50   | Very fast, low quality      |
    /// | veryfast   | 1         | 55   | Fast, acceptable quality    |
    /// | faster     | 1         | 60   | Fast                        |
    /// | fast       | 1         | 65   | Default preview sweet-spot  |
    /// | medium     | 0         | 72   | Balanced                    |
    /// | slow       | 0         | 80   | Higher quality              |
    /// | veryslow   | 0         | 90   | Best quality                |
    public enum SpeedPreset: String, Codable, Sendable {
        case ultrafast, superfast, veryfast, faster, fast, medium, slow, veryslow

        // MARK: VideoToolbox translation

        /// Whether to pass `-realtime 1` when encoding with a VideoToolbox codec.
        /// Enables real-time encoding priority in the hardware encoder — trades quality
        /// for latency/throughput, which is ideal for preview generation.
        public var videoToolboxRealtime: Bool {
            switch self {
            case .ultrafast, .superfast, .veryfast, .faster, .fast: return true
            case .medium, .slow, .veryslow:                          return false
            }
        }

        /// `-q:v` value (1–100, higher = better) passed to VideoToolbox encoders
        /// instead of the unsupported `-preset` / `-crf` flags.
        public var videoToolboxQuality: Int {
            switch self {
            case .ultrafast: return 40
            case .superfast: return 50
            case .veryfast:  return 55
            case .faster:    return 60
            case .fast:      return 65
            case .medium:    return 72
            case .slow:      return 80
            case .veryslow:  return 90
            }
        }
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

    // MARK: - Factories

    /// Derive encoding options from a normalised `compressionQuality` value (0.0–1.0),
    /// using software codecs (libx264/libx265). Mirrors the quality mapping of the SJS path.
    ///
    /// | Quality  | Codec | CRF | Preset | Max res |
    /// |----------|-------|-----|--------|---------|
    /// | 1.0      | HEVC  | 18  | slow   | 4K      |
    /// | 0.75–0.9 | H.264 | 20  | medium | 4K      |
    /// | 0.5–0.74 | H.264 | 23  | fast   | 1080p   |
    /// | < 0.5    | H.264 | 28  | fast   | 720p    |
    public static func from(quality: Double, format: VideoFormat) -> FFmpegEncodingOptions {
        if quality >= 1.0 {
            return FFmpegEncodingOptions(
                videoCodec: .hevc, crf: 18, speedPreset: .slow,
                maxResolution: ._4K, audioCodec: .aac, audioBitrate: "192k"
            )
        } else if quality >= 0.75 {
            return FFmpegEncodingOptions(
                videoCodec: .h264, crf: 20, speedPreset: .medium,
                maxResolution: ._4K, audioCodec: .aac, audioBitrate: "128k"
            )
        } else if quality >= 0.5 {
            return FFmpegEncodingOptions(
                videoCodec: .h264, crf: 23, speedPreset: .fast,
                maxResolution: ._1080p, audioCodec: .aac, audioBitrate: "128k"
            )
        } else {
            return FFmpegEncodingOptions(
                videoCodec: .h264, crf: 28, speedPreset: .fast,
                maxResolution: ._720p, audioCodec: .aac, audioBitrate: "128k"
            )
        }
    }

    /// Encoding options optimised for **preview generation** where speed is paramount.
    ///
    /// Always uses `hevc_videotoolbox` (Apple hardware encoder) with real-time mode enabled.
    /// The `compressionQuality` value only influences the `-q:v` level and output resolution cap.
    ///
    /// | Quality  | SpeedPreset | -q:v | Max res |
    /// |----------|-------------|------|---------|
    /// | ≥ 0.7    | fast        | 65   | 1080p   |
    /// | 0.4–0.69 | veryfast    | 55   | 1080p   |
    /// | < 0.4    | superfast   | 50   | 720p    |
    ///
    /// Falls back to software H.264 (`libx264`) via ``from(quality:format:)`` if you
    /// need cross-platform compatibility without VideoToolbox.
    public static func forPreview(quality: Double) -> FFmpegEncodingOptions {
        if quality >= 0.7 {
            return FFmpegEncodingOptions(
                videoCodec: .hevcVideoToolbox, crf: nil, speedPreset: .fast,
                maxResolution: ._1080p, audioCodec: .aac, audioBitrate: "128k"
            )
        } else if quality >= 0.4 {
            return FFmpegEncodingOptions(
                videoCodec: .hevcVideoToolbox, crf: nil, speedPreset: .veryfast,
                maxResolution: ._1080p, audioCodec: .aac, audioBitrate: "128k"
            )
        } else {
            return FFmpegEncodingOptions(
                videoCodec: .hevcVideoToolbox, crf: nil, speedPreset: .superfast,
                maxResolution: ._720p, audioCodec: .aac, audioBitrate: "128k"
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

        if videoCodec.isVideoToolbox {
            // ── VideoToolbox hardware path ──────────────────────────────────────
            // `-preset` and `-crf` are not supported by hardware encoders.
            // SpeedPreset is translated to:
            //   -realtime 1/0   real-time encoding hint (1 = prioritise speed)
            //   -q:v N          VideoToolbox quality level (1–100; higher = better)
            if speedPreset.videoToolboxRealtime {
                args += ["-realtime", "1"]
            }
            if let videoBitrate {
                // Explicit bitrate takes priority over quality-based control
                args += ["-b:v", videoBitrate]
            } else {
                args += ["-q:v", "\(speedPreset.videoToolboxQuality)"]
            }
        } else if videoCodec != .copy {
            // ── Software codec path (libx264 / libx265 / libaom-av1) ────────────
            if let crf {
                args += ["-crf", "\(crf)"]
            } else if let videoBitrate {
                args += ["-b:v", videoBitrate]
            }
            args += ["-preset", speedPreset.rawValue]
        }

        if videoCodec == .hevcVideoToolbox || videoCodec == .hevc {
            args += ["-tag:v", "hvc1"]
        }
        // Resolution filter — applied for all codecs except copy.
        // VideoToolbox needs this too: passthrough mode skips the AVVideoComposition,
        // so the intermediate .mov retains the source resolution; ffmpeg must scale.
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

        // Extra user-supplied args (escape hatch for e.g. -tag:v hvc1)
        args += extraArgs

        args.append(outputURL.path)
        return args
    }
}
