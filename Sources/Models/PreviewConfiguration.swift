//
//  PreviewConfiguration.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import AVFoundation
import OSLog
import SJSAssetExportSession

/// Configuration for video preview generation
@available(macOS 26, iOS 26, *)
public struct PreviewConfiguration: Codable, Sendable, Hashable {

    private static let logger = Logger(subsystem: "com.mosaickit", category: "PreviewConfiguration")

    // MARK: - Properties

    /// Target duration for the preview video (in seconds)
    public var targetDuration: TimeInterval

    /// Density level determining the number of extracts
    public var density: DensityConfig

    /// Output video format
    public var format: VideoFormat

    /// Whether to include audio in the preview
    public var includeAudio: Bool

    /// Output directory (if nil, uses video's parent directory)
    public var outputDirectory: URL?

    /// Whether to include full path in the output filename
    public var fullPathInName: Bool

    /// Compression quality (0.0 - 1.0, where 1.0 is highest quality)
    /// Used by the SJSAssetExportSession export path to determine codec and bitrate.
    public var compressionQuality: Double

    /// When true, uses AVAssetExportSession (Apple's native exporter) instead of SJSAssetExportSession.
    /// The native exporter uses preset-based quality control via ``exportPresetName``.
    public var useNativeExport: Bool

    /// The AVAssetExportSession preset to use when ``useNativeExport`` is true.
    /// If nil, a preset is automatically selected based on ``compressionQuality`` via ``VideoFormat/exportPreset(quality:)``.
    /// Common presets: AVAssetExportPresetHighestQuality, AVAssetExportPresetHEVC1920x1080,
    /// AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality, etc.
    public var exportPresetName: nativeExportPreset?
    
    
    public var sJSExportPresetName: SjSExportPreset?
    public var exportMaxResolution: ExportMaxResolution?
    // MARK: - Initialization

    public init(
        targetDuration: TimeInterval = 60, // 1 minute default
        density: DensityConfig = .m,
        format: VideoFormat = .mp4,
        includeAudio: Bool = true,
        outputDirectory: URL? = nil,
        fullPathInName: Bool = false,
        compressionQuality: Double = 0.8,
        useNativeExport: Bool = true,
        exportPresetName: nativeExportPreset? = .AVAssetExportPresetHEVC1920x1080,
        sjSExportPresetName: SjSExportPreset? = .hevc,
        maxResolution: ExportMaxResolution? = ._1080p
    ) {
        self.targetDuration = targetDuration
        self.density = density
        self.format = format
        self.includeAudio = includeAudio
        self.outputDirectory = outputDirectory
        self.fullPathInName = fullPathInName
        self.compressionQuality = min(max(compressionQuality, 0.0), 1.0)
        self.useNativeExport = useNativeExport
        self.exportPresetName = exportPresetName
        self.sJSExportPresetName = sjSExportPresetName ?? .hevc
        self.exportMaxResolution = maxResolution ?? ._1080p
    }

    
    
    /// The effective export preset: explicit ``exportPresetName`` if set, otherwise derived from quality.
    public var effectiveExportPreset: String {
        exportPresetName?.rawValue ?? format.exportPreset(quality: compressionQuality)
    }

    // MARK: - Codable (backward-compatible decoding)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetDuration = try container.decode(TimeInterval.self, forKey: .targetDuration)
        density = try container.decode(DensityConfig.self, forKey: .density)
        format = try container.decode(VideoFormat.self, forKey: .format)
        includeAudio = try container.decode(Bool.self, forKey: .includeAudio)
        outputDirectory = try container.decodeIfPresent(URL.self, forKey: .outputDirectory)
        fullPathInName = try container.decode(Bool.self, forKey: .fullPathInName)
        compressionQuality = min(max(try container.decode(Double.self, forKey: .compressionQuality), 0.0), 1.0)
        // New fields with backward-compatible defaults
        useNativeExport = try container.decodeIfPresent(Bool.self, forKey: .useNativeExport) ?? true
        exportPresetName = try container.decodeIfPresent(nativeExportPreset.self, forKey: .exportPresetName)
        sJSExportPresetName = try container.decodeIfPresent(SjSExportPreset.self, forKey: .sJSExportPresetName ) ?? .hevc
        exportMaxResolution = try container.decodeIfPresent(ExportMaxResolution.self, forKey: .exportMaxResolution) ?? ._1080p
    }

    // MARK: - Extract Calculation

    /// Base number of video extracts based on density (before duration adjustment)
    public var baseExtractCount: Int {
        switch density.name {
        case "XXL": return 4
        case "XL": return 8
        case "L": return 12
        case "M": return 16
        case "S": return 24
        case "XS": return 32
        case "XXS": return 48
        default:
            // For custom densities, calculate based on factor (base 16)
            return max(1, Int(16.0 * density.factor))
        }
    }
    
    public static func exterEtractCount(density: String) -> Int
    {switch density.uppercased() {
    case "XXL": return 4
    case "XL": return 8
    case "L": return 12
    case "M": return 16
    case "S": return 24
    case "XS": return 32
    case "XXS": return 48
    default:
        // For custom densities, calculate based on factor (base 16)
        return max(1,16)
    }
        
    }

    /// Calculate number of video extracts based on density and video duration
    /// - Parameter videoDuration: Duration of the input video in seconds
    /// - Returns: Total extract count (base count + duration-based adjustment)
    public func extractCount(forVideoDuration videoDuration: TimeInterval) -> Int {
        let durationAdjustment = ((videoDuration > 1800.00) ? 8.0 : 4.0) * log(videoDuration)
        let totalCount = Double(baseExtractCount) + durationAdjustment
        Self.logger.debug("extractCount(forVideoDuration:) -> \(totalCount)")
        return max(1, Int(totalCount.rounded()))
    }
    public static func extractCountExt(forVideoDuration videoDuration: TimeInterval, density: String, targetDuration: TimeInterval) -> Int {
        let durationAdjustment = ((videoDuration > 1800.00) ? 8.0 : 4.0) * log(videoDuration)
        let totalCount = Double(self.exterEtractCount(density: density)) + durationAdjustment
        Self.logger.debug("extractCount(forVideoDuration:) -> \(totalCount)")
        return max(1, Int(totalCount.rounded()))
    }
    

    /// Minimum duration for each extract (in seconds)
    public static let minimumExtractDuration: TimeInterval = 4.0

    /// Maximum playback speed multiplier
    public static let maximumPlaybackSpeed: Double = 1.5

    /// Calculate the duration per extract and playback speed
    /// - Parameter videoDuration: Duration of the input video in seconds
    /// - Returns: Tuple of (extractDuration, playbackSpeed)
    public func calculateExtractParameters(forVideoDuration videoDuration: TimeInterval) -> (extractDuration: TimeInterval, playbackSpeed: Double) {
        let count = extractCount(forVideoDuration: videoDuration)
        let baseExtractDuration = targetDuration / Double(count)

        if baseExtractDuration >= Self.minimumExtractDuration {
            // Each extract can be at least 2 seconds at normal speed
            return (baseExtractDuration, 1.0)
        } else {
            // Need to speed up playback to fit extracts
            let minimumTotalDuration = Self.minimumExtractDuration * Double(count)
            let requiredSpeed = minimumTotalDuration / targetDuration
            let cappedSpeed = min(requiredSpeed, Self.maximumPlaybackSpeed)

            // Calculate actual extract duration based on capped speed
            let actualExtractDuration = targetDuration * cappedSpeed / Double(count)

            return (actualExtractDuration, cappedSpeed)
        }
    }

    // MARK: - Output Path Generation

    /// Generate output directory for preview video
    /// - Parameters:
    ///   - videoInput: The source video
    /// - Returns: URL for output directory
    public func generateOutputDirectory(for videoInput: VideoInput) -> URL {
        let baseDirectory = outputDirectory ?? videoInput.url.deletingLastPathComponent()
        return baseDirectory
            .appendingPathComponent("movieprev", isDirectory: true)
    }

    /// Generate filename for the preview video
    /// - Parameters:
    ///   - videoInput: The source video
    /// - Returns: Filename string
    public func generateFilename(for videoInput: VideoInput) -> String {
        let originalFilename = videoInput.url.deletingPathExtension().lastPathComponent

        let durationLabel = formatDuration(targetDuration)
        let audioLabel = includeAudio ? "audio" : "noaudio"
        let exportLabel: String
        let resolution = exportMaxResolution?.rawValue ?? "auto"
        if useNativeExport {
            let preset = (exportPresetName?.displayString ?? effectiveExportPreset)
              //  .replacingOccurrences(of: "AVAssetExportPreset", with: "")
            exportLabel = "\(preset)_nat"
        } else {
            let codec = sJSExportPresetName?.displayString ?? "default"
         //   let res = exportMaxResolution?.rawValue ?? "auto"
            exportLabel = "\(codec)_sjs"
        }
        let configHash = "\(durationLabel)_\(density.name)_\(format.rawValue)_\(audioLabel)_\(exportLabel)_\(resolution)"
      
        if fullPathInName {
            // Use full path in filename
            let sanitizedPath = videoInput.url.deletingLastPathComponent().path
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            return "\(sanitizedPath)_\(originalFilename)_preview_\(configHash).\(format.fileExtension)"
        } else {
            return "\(originalFilename)_preview_\(configHash).\(format.fileExtension)"
        }
    }

    /// Format duration for filename (e.g., "30s", "1m", "2m30s")
    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes == 0 {
            return "\(seconds)s"
        } else if seconds == 0 {
            return "\(minutes)m"
        } else {
            return "\(minutes)m\(seconds)s"
        }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(targetDuration)
        hasher.combine(density)
        hasher.combine(format)
        hasher.combine(includeAudio)
        hasher.combine(compressionQuality)
        hasher.combine(useNativeExport)
        hasher.combine(exportPresetName)
    }
}

// MARK: - Predefined Durations

@available(macOS 26, iOS 26, *)
extension PreviewConfiguration {
    /// Common preview durations (30 second increments from 30s to 5m)
    public static let standardDurations: [TimeInterval] = [
        30,    // 30 seconds
        60,    // 1 minute
        90,    // 1:30
        120,   // 2 minutes
        150,   // 2:30
        180,   // 3 minutes
        210,   // 3:30
        240,   // 4 minutes
        270,   // 4:30
        300    // 5 minutes
    ]

    /// Get display label for a duration
    public static func durationLabel(for duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes == 0 {
            return "\(seconds)s"
        } else if seconds == 0 {
            return "\(minutes)m"
        } else {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
    }
}
extension PreviewConfiguration: CustomDebugStringConvertible {
    public var debugDescription: String {
        let durationLabel = Self.durationLabel(for: targetDuration)
        let audioLabel = includeAudio ? "audio" : "no audio"
        let exportDetail: String
        if useNativeExport {
            exportDetail = "native(preset: \(exportPresetName?.displayString ?? effectiveExportPreset))"
        } else {
            let codec = sJSExportPresetName?.displayString ?? "default"
            let res = exportMaxResolution?.rawValue ?? "auto"
            exportDetail = "SJS(codec: \(codec), maxRes: \(res))"
        }
        return "PreviewConfiguration(duration: \(durationLabel), density: \(density.name), format: \(format.rawValue), \(audioLabel), export: \(exportDetail))"
    }
}
