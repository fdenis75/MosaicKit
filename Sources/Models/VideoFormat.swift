import Foundation
import AVFoundation
import CoreGraphics
import SJSAssetExportSession

/// An enumeration representing the AVAssetExportSession presets for native video export.
public enum nativeExportPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: Self {
        return self
    }
    /// A passthrough preset that preserves the original video encoding.
    case AVAssetExportPresetPassthrough = "AVAssetExportPresetPassthrough"
    /// A highest quality HEVC (H.265) preset.
    case AVAssetExportPresetHEVCHighestQuality = "AVAssetExportPresetHEVCHighestQuality"
    /// A 1080p (1920x1080) HEVC (H.265) preset.
    case AVAssetExportPresetHEVC1920x1080 = "AVAssetExportPresetHEVC1920x1080"
    /// A highest quality H.264 preset.
    case AVAssetExportPresetHighestQuality = "AVAssetExportPresetHighestQuality"
    /// A medium quality H.264 preset.
    case AVAssetExportPresetMediumQuality = "AVAssetExportPresetMediumQuality"
    /// A low quality H.264 preset.
    case AVAssetExportPresetLowQuality = "AVAssetExportPresetLowQuality"
    /// An SD quality H.264 preset (960x540).
    case AVAssetExportPreset960x540 = "AVAssetExportPreset960x540"
//let preset = AVAssetExportPreset960x540
    /// The codec identifier associated with the preset.
    public var codec: String {
        switch self {
        case .AVAssetExportPresetPassthrough:
            return "passthrough"
        case .AVAssetExportPresetHighestQuality, .AVAssetExportPresetMediumQuality, .AVAssetExportPresetLowQuality, .AVAssetExportPreset960x540:
            return "h264"
        case .AVAssetExportPresetHEVC1920x1080, .AVAssetExportPresetHEVCHighestQuality:
            return "hevc"
        }
    }
    
    /// A human-readable display string for the preset.
    public var displayString: String {
        switch self {
        case .AVAssetExportPresetPassthrough:
            return "Passthrough"
        case .AVAssetExportPresetHEVCHighestQuality:
            return "HEVC Highest"
        case .AVAssetExportPresetHEVC1920x1080:
            return "HEVC High"
        case .AVAssetExportPresetHighestQuality:
            return "H264 Highest"
        case .AVAssetExportPresetMediumQuality:
            return "H264 Medium"
        case .AVAssetExportPresetLowQuality:
            return "H264 Low"
        case .AVAssetExportPreset960x540:
            return "H264 SD"
        }
    }
    
    /// A human-readable display string for the preset.
    public var fileString: String {
        switch self {
        case .AVAssetExportPresetPassthrough:
            return "Passthrough"
        case .AVAssetExportPresetHEVCHighestQuality:
            return "HEVC_Highest"
        case .AVAssetExportPresetHEVC1920x1080:
            return "HEVC_High"
        case .AVAssetExportPresetHighestQuality:
            return "H264_Highest"
        case .AVAssetExportPresetMediumQuality:
            return "H264_Medium"
        case .AVAssetExportPresetLowQuality:
            return "H264_Low"
        case .AVAssetExportPreset960x540:
            return "H264_SD"
        }
    }
 
    /// The maximum resolution string representation of the preset.
    public var MaxResolution: String {
        switch self {
        case .AVAssetExportPresetPassthrough, .AVAssetExportPresetHighestQuality, .AVAssetExportPresetMediumQuality, .AVAssetExportPresetLowQuality, .AVAssetExportPresetHEVCHighestQuality:
            return "same as Source"
        case .AVAssetExportPreset960x540:
            return "540p"
        case .AVAssetExportPresetHEVC1920x1080:
            return "1920x1080"
        }
    }
    
    /// An array of all available native export presets.
    public static let allCases: [nativeExportPreset] = [.AVAssetExportPresetPassthrough, .AVAssetExportPresetHighestQuality, .AVAssetExportPresetMediumQuality, .AVAssetExportPresetLowQuality, .AVAssetExportPreset960x540, .AVAssetExportPresetHEVC1920x1080, .AVAssetExportPresetHEVCHighestQuality]

    /// Technical details (codec, profile, level, resolution) produced by `AVAssetExportSession`
    /// for this preset. Values are derived from real exports of a 3840x2160 source.
    public var profile: NativeExportPresetProfile {
        switch self {
        case .AVAssetExportPresetPassthrough:
            return NativeExportPresetProfile(
                codec: nil, profile: "High", level: "5.1",
                maxResolution: nil,
                resolutionDescription: "Same as source (original encoding preserved)"
            )
        case .AVAssetExportPresetHEVCHighestQuality:
            return NativeExportPresetProfile(
                codec: .hevc, profile: "Main", level: "5.0",
                maxResolution: nil,
                resolutionDescription: "Same as source"
            )
        case .AVAssetExportPresetHEVC1920x1080:
            return NativeExportPresetProfile(
                codec: .hevc, profile: "Main", level: "4.0",
                maxResolution: CGSize(width: 1920, height: 1080),
                resolutionDescription: "1920x1080 (1080p)"
            )
        case .AVAssetExportPresetHighestQuality:
            return NativeExportPresetProfile(
                codec: .h264, profile: "High", level: "5.1",
                maxResolution: nil,
                resolutionDescription: "Same as source"
            )
        case .AVAssetExportPresetMediumQuality:
            return NativeExportPresetProfile(
                codec: .h264, profile: "Main", level: "3.0",
                maxResolution: nil,
                resolutionDescription: "Source-dependent downscale (e.g. ~568x320 for a 3840x2160 source)"
            )
        case .AVAssetExportPresetLowQuality:
            return NativeExportPresetProfile(
                codec: .h264, profile: "Baseline", level: "1.1",
                maxResolution: nil,
                resolutionDescription: "Source-dependent downscale, reduced frame rate (e.g. ~224x128 @15fps for a 3840x2160 source)"
            )
        case .AVAssetExportPreset960x540:
            return NativeExportPresetProfile(
                codec: .h264, profile: "Main", level: "3.1",
                maxResolution: CGSize(width: 960, height: 540),
                resolutionDescription: "960x540 (SD)"
            )
        }
    }
}

extension nativeExportPreset {
    /// Resolves the maximum output resolution forced by `presetName`, whether or not it
    /// maps to a ``nativeExportPreset`` case.
    ///
    /// Falls back to inspecting common `AVAssetExportSession` preset name patterns
    /// (e.g. `"...1920x1080"`) for raw preset strings outside this enum, so callers can
    /// pass `PreviewConfiguration.effectiveExportPreset` directly.
    ///
    /// - Returns: `nil` when the preset preserves the source resolution.
    public static func maxResolution(forPresetName presetName: String) -> CGSize? {
        if let preset = nativeExportPreset(rawValue: presetName) {
            return preset.profile.maxResolution
        }
        if presetName.contains("3840x2160") {
            return CGSize(width: 3840, height: 2160)
        } else if presetName.contains("1920x1080") {
            return CGSize(width: 1920, height: 1080)
        } else if presetName.contains("960x540") {
            return CGSize(width: 960, height: 540)
        } else if presetName.contains("1280x720") {
            return CGSize(width: 1280, height: 720)
        }
        return nil
    }
}

/// Describes the technical characteristics of a ``nativeExportPreset`` as produced by
/// `AVAssetExportSession`, for display purposes (e.g. preset picker detail views).
public struct NativeExportPresetProfile: Sendable, Hashable {
    /// The encoded video codec, or `nil` for ``nativeExportPreset/AVAssetExportPresetPassthrough``
    /// (which preserves the source codec unchanged).
    public let codec: Codec?

    /// The H.264/HEVC encoding profile (e.g. `"Baseline"`, `"Main"`, `"High"`).
    public let profile: String

    /// The encoding level (e.g. `"3.1"`, `"5.1"`).
    public let level: String

    /// The maximum output resolution enforced by the preset, or `nil` when the preset
    /// preserves the source resolution (e.g. Passthrough, Highest Quality presets).
    public let maxResolution: CGSize?

    /// A human-readable summary of the preset's resolution behaviour.
    public let resolutionDescription: String
}



/// An enumeration representing the SJSAssetExportSession presets for custom video export with codec and quality control.
public enum SjSExportPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: Self {
        return self
    }
    /// An HEVC high quality preset.
    case hevc  = "HEVC"
    /// An H.264 high auto level preset.
    case h264_HighAutoLevel = "HEVC High"
    /// An H.264 low auto level preset.
    case h264_lowAutoLevel = "H264 LOW"
    
    /// The underlying `VideoOutputSettings.Codec` associated with the preset.
    public var SJSCodec: VideoOutputSettings.Codec {
        switch self {
        case .hevc:
            return .hevc
        case .h264_HighAutoLevel:
            return .h264(.highAuto)
        case .h264_lowAutoLevel:
            return .h264(.baselineAuto)
        }
    }
    
    /// The export quality associated with the preset.
    public var exportQuality: ExportQuality {
        switch self {
        case .hevc:
            return .NonApplicable
        case .h264_HighAutoLevel:
            return .high
        case .h264_lowAutoLevel:
            return .low
        }
    }
    
    /// A human-readable display string for the preset.
    public var displayString: String {
        switch self {
        case .hevc:
            return "HEVC High"
        case .h264_HighAutoLevel:
            return "H264 High"
        case .h264_lowAutoLevel:
            return "H264 Low"
        }
    }
}

/// An enumeration representing the maximum output resolution constraints for video export.
///
/// Only available on macOS 26+ and iOS 26+ because the actual downscaling is performed
/// using `AVVideoComposition.Configuration`, `AVVideoCompositionLayerInstruction.Configuration`,
/// and `AVVideoCompositionInstruction.Configuration` — all APIs introduced in macOS 26 / iOS 26.
///
/// On earlier OS versions the setting is stored but silently ignored; the full source
/// resolution is used during export. Use `#available(macOS 26, iOS 26, *)` guards whenever
/// you read or write this value.
@available(macOS 26, iOS 26, *)
public enum ExportMaxResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: Self {
        return self
    }
    /// A 1080p maximum resolution.
    case _1080p = "1080p"
    /// A 4K maximum resolution.
    case _4K = "4K"
    /// A 720p maximum resolution.
    case _720p = "720p"
    /// An SD maximum resolution.
    case SD = "SD"
    
    /// The maximum width in pixels for the resolution constraint.
    public var maxWidth: Int {
        switch self {
        case ._1080p:
            return 1920
        case ._4K:
            return 3840
        case ._720p:
            return 1280
        case .SD:
            return 640
        }
    }
    
    /// The maximum height in pixels for the resolution constraint.
    public var maxHeight: Int {
        switch self {
        case ._1080p:
            return 1080
        case ._4K:
            return 2160
        case ._720p:
            return 720
        case .SD:
            return 480
        }
    }

    /// Alias for ``maxWidth``, matching the naming used by `FFmpegEncodingOptions`'s
    /// now-unified resolution type.
    public var width: Int { maxWidth }

    /// Alias for ``maxHeight``, matching the naming used by `FFmpegEncodingOptions`'s
    /// now-unified resolution type.
    public var height: Int { maxHeight }

    /// The resolution constraint expressed as a `CGSize`.
    public var cgSize: CGSize { CGSize(width: maxWidth, height: maxHeight) }

    /// `scale` filter argument string that downscales to fit within this resolution while
    /// preserving aspect ratio. Never upscales; has no effect when the source is already smaller.
    /// Suitable for direct use as the value of the ffmpeg `-vf` option (no shell quoting needed
    /// since arguments are passed as an array, not via a shell).
    public var scaleFilter: String {
        "scale='min(\(maxWidth),iw)':'min(ih,\(maxHeight))'"
    }

    /// Alias for ``SD``, matching the lowercase case name previously used by
    /// `FFmpegEncodingOptions.MaxResolution`.
    public static let sd: ExportMaxResolution = .SD
}

/// An enumeration representing the video codec identifiers.
public enum Codec: String, Codable, Sendable, CaseIterable {
    /// High Efficiency Video Coding (H.265).
    case hevc = "hevc"
    /// Advanced Video Coding (H.264).
    case h264 = "h264"
}

/// An enumeration representing the export quality levels for SJSAssetExportSession presets.
public enum ExportQuality: String, Codable, Sendable, CaseIterable {
    /// The quality is not applicable for this preset.
    case NonApplicable = "NON_APPLICABLE"
    /// High quality.
    case high = "HIGH"
    /// Low quality.
    case low = "LOW"
}

/// An enumeration representing the supported video output formats for preview generation.
public enum VideoFormat: String, Codable, Sendable, CaseIterable, CustomDebugStringConvertible {
    /// MPEG-4 format (.mp4).
    case mp4 = "mp4"
    /// QuickTime Movie format (.mov).
    case mov = "mov"
    /// MPEG-4 video format (.m4v).
    case m4v = "m4v"
    
    /// The file extension associated with the format.
    public var fileExtension: String {
        return rawValue
    }
    
    /// The `AVFileType` associated with the format.
    public var avFileType: AVFileType {
        switch self {
        case .mp4:
            return .mp4
        case .mov:
            return .mov
        case .m4v:
            return .m4v
        }
    }

    /// A human-readable display name for the format.
    public var displayName: String {
        switch self {
        case .mp4:
            return "MP4"
        case .mov:
            return "MOV (QuickTime)"
        case .m4v:
            return "M4V (iTunes)"
        }
    }

    /// A debug description representing the format.
    public var debugDescription: String {
        "\(displayName) (.\(rawValue), AVFileType: \(avFileType.rawValue))"
    }

    /// Returns the recommended export preset string based on the target quality.
    ///
    /// - Parameter quality: The compression quality (ranging from 0.0 to 1.0).
    /// - Returns: An `AVAssetExportSession` preset identifier.
    public func exportPreset(quality: Double) -> String {
        // Higher quality -> higher resolution preset
        if quality == 1.0 {
            return AVAssetExportPresetHEVCHighestQuality
        } else if quality == 0.9 {
            return  AVAssetExportPresetHEVC1920x1080 // Highest quality H.265
        } else if quality == 0.8 {
            return AVAssetExportPresetHighestQuality
        } else if quality == 0.7 {
            return AVAssetExportPreset1920x1080// 1080p HEVC
        } else if quality == 0.7 {
            return AVAssetExportPresetMediumQuality // 1080p H.264
        } else if quality == 0.5 {
            return AVAssetExportPresetLowQuality // Medium quality H.264
        } else if quality == 0.4 {
            return AVAssetExportPreset960x540 // Low quality H.264
        } else {
            return AVAssetExportPresetPassthrough // passthrough
        }
    }
}
