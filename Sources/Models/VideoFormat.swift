//
//  VideoFormat.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import AVFoundation
import SJSAssetExportSession

public enum nativeExportPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: Self {

           return self
       }
    case AVAssetExportPresetPassthrough = "AVAssetExportPresetPassthrough"
   
    case AVAssetExportPresetHEVC1920x1080 = "AVAssetExportPresetHEVC1920x1080"
    case AVAssetExportPresetHighestQuality = "AVAssetExportPresetHighestQuality"
    
    case AVAssetExportPresetMediumQuality = "AVAssetExportPresetMediumQuality"
    case AVAssetExportPresetLowQuality = "AVAssetExportPresetLowQuality"
    
    case AVAssetExportPreset960x540 = "AVAssetExportPreset960x540"
    
    public var codec: String {
        switch self {
        case .AVAssetExportPresetPassthrough:
            return "passthrough"
        case .AVAssetExportPresetHighestQuality, .AVAssetExportPresetMediumQuality, .AVAssetExportPresetLowQuality, .AVAssetExportPreset960x540:
            return "h264"
        case .AVAssetExportPresetHEVC1920x1080:
            return "hevc"
        }
    }
    
    public var displayString: String {
        switch self {
        case .AVAssetExportPresetPassthrough:
            return "Passthrough"
        case .AVAssetExportPresetHEVC1920x1080:
            return "HEVC_Hi"
        case .AVAssetExportPresetHighestQuality:
            return "H264_Hi"
        case .AVAssetExportPresetMediumQuality:
            return "H264_Med"
        case .AVAssetExportPresetLowQuality:
            return "H264-Lo"
        case .AVAssetExportPreset960x540:
            return "H264_sd"
        }
    }
 
    public var MaxResolution: String {
        switch self {
            case .AVAssetExportPresetPassthrough, .AVAssetExportPresetHighestQuality, .AVAssetExportPresetMediumQuality, .AVAssetExportPresetLowQuality:
            return "same as Source"
            case .AVAssetExportPreset960x540:
            return "540p"
        case .AVAssetExportPresetHEVC1920x1080:
            return "1920x1080"
        }
    }
    
    public static let allCases: [nativeExportPreset] = [.AVAssetExportPresetPassthrough, .AVAssetExportPresetHighestQuality, .AVAssetExportPresetMediumQuality, .AVAssetExportPresetLowQuality, .AVAssetExportPreset960x540, .AVAssetExportPresetHEVC1920x1080]
}
    

public enum SjSExportPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: Self {

           return self
       }
    case hevc  = "Hevc"
    case h264_HighAutoLevel = "H264_HIGH_AUTO_LEVEL"
    case h264_lowAutoLevel = "H264_LOW_AUTO_LEVEL"
    
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
    
    public var displayString: String
    {
        switch self {
        case .hevc:
            return "HEVC_Hi"
        case .h264_HighAutoLevel:
            return "H264_Hi"
        case .h264_lowAutoLevel:
            return "H264_Lo"
      
        }
    }
    
}

public enum ExportMaxResolution: String, Codable, Sendable, CaseIterable,Identifiable {
    public var id: Self {

           return self
       }
    case _1080p = "1080p"
    case _4K = "4K"
    case _720p = "720p"
    case SD = "SD"
    
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

public enum Codec: String, Codable, Sendable, CaseIterable {
    case hevc = "hevc"
    case h264 = "h264"
}

public enum ExportQuality: String, Codable, Sendable, CaseIterable {
    case NonApplicable = "NON_APPLICABLE"
    case high = "HIGH"
    case low = "LOW"
    
}

/// Supported video output formats for preview generation
@available(macOS 26, iOS 26, *)
    public enum VideoFormat: String, Codable, Sendable, CaseIterable, CustomDebugStringConvertible {
        case mp4 = "mp4"
        case mov = "mov"
        case m4v = "m4v"
        
        /// File extension for the format
        public var fileExtension: String {
            return rawValue
        }
        
        /// AVFoundation file type
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
    

    /// Display name for UI
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

    /// Recommended export preset based on format and quality
    /// - Parameter quality: Compression quality (0.0-1.0)
    /// - Returns: AVAssetExportSession preset name
    public var debugDescription: String {
        "\(displayName) (.\(rawValue), AVFileType: \(avFileType.rawValue))"
    }

    public func exportPreset(quality: Double) -> String {
        // Higher quality -> higher resolution preset
        if quality == 1.0 {
            return AVAssetExportPresetPassthrough // 4K HEVC
        } else if quality == 0.9 {
            return AVAssetExportPresetHighestQuality // 1080p HEVC
        } else if quality == 0.8 {
            return AVAssetExportPresetHEVC1920x1080 // 1080p H.264
        } else if quality == 0.7 {
            return AVAssetExportPreset1920x1080 // 1080p H.264
        }
        else if quality == 0.6 {
            return AVAssetExportPresetMediumQuality // 1080p H.264
        }else if quality == 0.5 {
            return AVAssetExportPresetLowQuality // 1080p H.264
        }
        else {
            return AVAssetExportPreset960x540 // 720p H.264
        }
    }
    
    
    
}
