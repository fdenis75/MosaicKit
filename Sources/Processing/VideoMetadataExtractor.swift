//
//  VideoMetadataExtractor.swift
//  GigaMovie2
//
//  Created by Claude Code on 03/12/2025.
//

import Foundation
import AVFoundation
import CoreMedia

/// Sendable struct for metadata values
struct VideoMetadataValues: Sendable {
    let duration: TimeInterval
    let resolution: String?
    let frameRate: Double?
    let videoCodec: String?
    let audioCodec: String?
    let bitrate: Int64?
    let hasAudio: Bool
    let fileCreationDate: Date?
    let width: Double?
    let height: Double?
    let fileSize: Int64?
}

actor VideoMetadataExtractor {
    /// Extract comprehensive metadata from a video file (returns Sendable values)
    /// Optimized for performance with parallel property loading
    func extractMetadataValues(from url: URL) async throws -> VideoMetadataValues {
        let asset = AVURLAsset(url: url)

        // Load multiple properties at once for better performance
        let (tracks, duration) = try await asset.load(.tracks, .duration)
       
        var resolution: String?
        var frameRate: Double?
        var videoCodec: String?
        var audioCodec: String?
        var bitrate: Int64?
        var height: Double?
        var width: Double?
        var fileSize: Int64?
         fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        // Find video track and load properties
        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            // Load multiple track properties at once for better performance
            let (size, fps, formats) = try await videoTrack.load(.naturalSize, .nominalFrameRate, .formatDescriptions)

            resolution = "\(Int(size.width))×\(Int(size.height))"
            width = Double(size.width)
            height = Double(size.height)
            frameRate = Double(fps)

            if let formatDescription = formats.first {
                let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
                videoCodec = codecTypeToString(codecType)
            }
        }

        // Find audio track
        let hasAudio = tracks.contains(where: { $0.mediaType == .audio })

        if hasAudio, let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
            let formats = try? await audioTrack.load(.formatDescriptions)

            if let formats = formats,
               let formatDescription = formats.first {
                let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
                audioCodec = codecTypeToString(codecType)
            }
        }

        // Calculate bitrate from file size and duration (more reliable than estimatedDataRate)
        bitrate = calculateBitrate(for: url, duration: duration.seconds)

        // Extract file creation date
        let fileCreationDate = extractFileCreationDate(from: url)

        return VideoMetadataValues(
            duration: duration.seconds,
            resolution: resolution,
            frameRate: frameRate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            bitrate: bitrate,
            hasAudio: hasAudio,
            fileCreationDate: fileCreationDate,
            width: width,
            height: height,
            fileSize: fileSize
        )
    }

    /// Extract file creation date from file attributes
    private func extractFileCreationDate(from url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.creationDate] as? Date
    }

    /// Calculate bitrate from file size and duration
    private func calculateBitrate(for url: URL, duration: TimeInterval) -> Int64? {
        guard duration > 0 else { return nil }

        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              fileSize > 0 else {
            return nil
        }

        // Convert to bits per second
        return Int64((Double(fileSize) * 8) / duration)
    }


    /// Convert codec FourCC to readable string
    private func codecTypeToString(_ codecType: FourCharCode) -> String {
        switch codecType {
        case kCMVideoCodecType_H264:
            return "H.264"
        case kCMVideoCodecType_HEVC:
            return "HEVC (H.265)"
        case kCMVideoCodecType_VP9:
            return "VP9"
        case kCMVideoCodecType_AV1:
            return "AV1"
        case kCMVideoCodecType_AppleProRes422:
            return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444:
            return "ProRes 4444"
        case kAudioFormatMPEG4AAC:
            return "AAC"
        case kAudioFormatAC3:
            return "AC3"
        default:
            // Convert FourCC to string
            let bytes: [UInt8] = [
                UInt8((codecType >> 24) & 0xFF),
                UInt8((codecType >> 16) & 0xFF),
                UInt8((codecType >> 8) & 0xFF),
                UInt8(codecType & 0xFF)
            ]
            return String(bytes: bytes, encoding: .ascii) ?? "Unknown"
        }
    }

    /// Get video duration in seconds
    func getDuration(from url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds
    }
}
