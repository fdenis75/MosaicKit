//
//  PreviewConfiguration.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import AVFoundation

/// Configuration for video preview generation
@available(macOS 15, iOS 18, *)
public struct PreviewConfiguration: Codable, Sendable, Hashable {

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
    public var compressionQuality: Double

    // MARK: - Initialization

    public init(
        targetDuration: TimeInterval = 60, // 1 minute default
        density: DensityConfig = .m,
        format: VideoFormat = .mp4,
        includeAudio: Bool = true,
        outputDirectory: URL? = nil,
        fullPathInName: Bool = false,
        compressionQuality: Double = 0.8
    ) {
        self.targetDuration = targetDuration
        self.density = density
        self.format = format
        self.includeAudio = includeAudio
        self.outputDirectory = outputDirectory
        self.fullPathInName = fullPathInName
        self.compressionQuality = compressionQuality
    }

    // MARK: - Extract Calculation

    /// Number of video extracts based on density
    public var extractCount: Int {
        switch density.name {
        case "XXL": return 4
        case "XL": return 8
        case "L": return 12
        case "M": return 16
        case "S": return 24
        case "XS": return 32
        case "XXS": return 48
        case "XXS": return 48
        default: 
            // For custom densities, calculate based on factor (base 16)
            return max(1, Int(16.0 * density.factor))
        }
    }

    /// Minimum duration for each extract (in seconds)
    public static let minimumExtractDuration: TimeInterval = 2.0

    /// Maximum playback speed multiplier
    public static let maximumPlaybackSpeed: Double = 4.0

    /// Calculate the duration per extract and playback speed
    /// - Returns: Tuple of (extractDuration, playbackSpeed)
    public func calculateExtractParameters() -> (extractDuration: TimeInterval, playbackSpeed: Double) {
        let baseExtractDuration = targetDuration / Double(extractCount)

        if baseExtractDuration >= Self.minimumExtractDuration {
            // Each extract can be at least 2 seconds at normal speed
            return (baseExtractDuration, 1.0)
        } else {
            // Need to speed up playback to fit extracts
            let minimumTotalDuration = Self.minimumExtractDuration * Double(extractCount)
            let requiredSpeed = minimumTotalDuration / targetDuration
            let cappedSpeed = min(requiredSpeed, Self.maximumPlaybackSpeed)

            // Calculate actual extract duration based on capped speed
            let actualExtractDuration = targetDuration * cappedSpeed / Double(extractCount)

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

        // Create config hash: duration_density_format_audio
        let durationLabel = formatDuration(targetDuration)
        let audioLabel = includeAudio ? "audio" : "noaudio"
        let quality = compressionQuality.isNaN ? "" : "_\(compressionQuality)"
        let configHash = "\(durationLabel)_\(density.name)_\(format.rawValue)_\(audioLabel)_\(quality)"
      
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
    }
}

// MARK: - Predefined Durations

@available(macOS 15, iOS 18, *)
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
