import Foundation
import AVFoundation
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
