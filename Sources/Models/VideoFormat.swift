//
//  VideoFormat.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import AVFoundation

/// Supported video output formats for preview generation
@available(macOS 26, iOS 26, *)
public enum VideoFormat: String, Codable, Sendable, CaseIterable {
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
    public func exportPreset(quality: Double) -> String {
        // Higher quality -> higher resolution preset
        if quality >= 0.9 {
            return AVAssetExportPresetHEVC3840x2160 // 4K HEVC
        } else if quality >= 0.75 {
            return AVAssetExportPresetHEVC1920x1080 // 1080p HEVC
        } else if quality >= 0.5 {
            return AVAssetExportPreset1920x1080 // 1080p H.264
        } else {
            return AVAssetExportPreset1280x720 // 720p H.264
        }
    }
}
