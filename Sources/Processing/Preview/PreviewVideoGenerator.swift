//
//  PreviewVideoGenerator.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import AVFoundation
import OSLog

/// Actor responsible for generating preview videos from source videos
@available(macOS 15, iOS 18, *)
public actor PreviewVideoGenerator {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.mosaickit", category: "PreviewVideoGenerator")
    private var progressHandlers: [UUID: @Sendable (PreviewGenerationProgress) -> Void] = [:]
    private var cancellationFlags: [UUID: Bool] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Generate a preview video
    /// - Parameters:
    ///   - video: The source video
    ///   - config: Preview configuration
    /// - Returns: URL of the generated preview
    public func generate(
        for video: VideoInput,
        config: PreviewConfiguration
    ) async throws -> URL {
        logger.info("Starting preview generation for \(video.title)")

        // Check for cancellation
        if cancellationFlags[video.id] == true {
            throw PreviewError.cancelled
        }

        // Report analyzing status
        reportProgress(for: video, progress: 0.0, status: .analyzing)

        // Load the video asset
        let asset = AVURLAsset(url: video.url)

        // Validate video
        try await validateVideo(asset: asset, video: video, config: config)

        // Calculate extract parameters
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters()
        logger.info("Extract duration: \(extractDuration)s, playback speed: \(playbackSpeed)x")

        // Calculate timestamps for extracts
        reportProgress(for: video, progress: 0.1, status: .analyzing, message: "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: config.extractCount,
            extractDuration: extractDuration
        )

        // Check for cancellation
        if cancellationFlags[video.id] == true {
            throw PreviewError.cancelled
        }

        // Extract video segments
        reportProgress(for: video, progress: 0.2, status: .extracting, message: "Extracting \(timestamps.count) segments...")
        let videoComposition = try await composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            video: video
        )

        // Check for cancellation
        if cancellationFlags[video.id] == true {
            throw PreviewError.cancelled
        }

        // Export the composition
        reportProgress(for: video, progress: 0.7, status: .encoding, message: "Encoding preview video...")
        let outputURL = try await exportComposition(
            composition: videoComposition.composition,
            audioMix: videoComposition.audioMix,
            config: config,
            video: video
        )

        // Report completion
        reportProgress(for: video, progress: 1.0, status: .completed)
        logger.info("Preview generation completed: \(outputURL.lastPathComponent)")

        // Cleanup
        cancellationFlags.removeValue(forKey: video.id)

        return outputURL
    }

    /// Set progress handler for a video
    public func setProgressHandler(
        for video: VideoInput,
        handler: @escaping @Sendable (PreviewGenerationProgress) -> Void
    ) {
        progressHandlers[video.id] = handler
    }

    /// Cancel generation for a specific video
    public func cancel(for video: VideoInput) {
        logger.info("Cancelling preview generation for \(video.title)")
        cancellationFlags[video.id] = true
    }

    /// Cancel all active generations
    public func cancelAll() {
        logger.info("Cancelling all preview generations")
        for id in cancellationFlags.keys {
            cancellationFlags[id] = true
        }
    }

    // MARK: - Private Methods

    private func validateVideo(asset: AVAsset, video: VideoInput, config: PreviewConfiguration) async throws {
        logger.info("🔍 Validating video: \(video.title)")

        // Check for video tracks
        let tracks = try await asset.loadTracks(withMediaType: .video)
        logger.info("📹 Video tracks found: \(tracks.count)")

        guard !tracks.isEmpty else {
            logger.error("❌ No video tracks in asset")
            throw PreviewError.noVideoTracks
        }

        // Log track details
        for (index, track) in tracks.enumerated() {
            let naturalSize = try await track.load(.naturalSize)
            let nominalFrameRate = try await track.load(.nominalFrameRate)
            logger.info("  Track \(index): \(naturalSize.width)x\(naturalSize.height) @ \(nominalFrameRate)fps")
        }

        // Check duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        logger.info("⏱️  Video duration: \(durationSeconds)s")

        // Minimum required duration: at least enough for the minimum extract duration
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters()
        let minimumRequired = extractDuration * Double(config.extractCount)

        logger.info("📊 Extract parameters:")
        logger.info("  - Extract count: \(config.extractCount)")
        logger.info("  - Extract duration: \(extractDuration)s")
        logger.info("  - Playback speed: \(playbackSpeed)x")
        logger.info("  - Minimum required video duration: \(minimumRequired)s")

        guard durationSeconds >= minimumRequired else {
            logger.error("❌ Video too short: \(durationSeconds)s < \(minimumRequired)s")
            throw PreviewError.insufficientVideoDuration(
                required: minimumRequired,
                actual: durationSeconds
            )
        }

        logger.info("✅ Video validation passed")
    }

    private func calculateExtractTimestamps(
        asset: AVAsset,
        video: VideoInput,
        extractCount: Int,
        extractDuration: TimeInterval
    ) async throws -> [(start: CMTime, duration: CMTime)] {
        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)

        // Use biased distribution (skip first/last 5%, concentrate in middle)
        let skipStart = totalDuration * 0.05
        let skipEnd = totalDuration * 0.05
        let usableDuration = totalDuration - skipStart - skipEnd

        // Divide into thirds with different weights
        let firstThirdEnd = skipStart + (usableDuration * 0.333)
        let secondThirdEnd = skipStart + (usableDuration * 0.667)

        // Allocate extracts: 20% in first third, 60% in middle, 20% in last third
        let firstThirdCount = max(1, Int(Double(extractCount) * 0.2))
        let middleThirdCount = max(1, Int(Double(extractCount) * 0.6))
        let lastThirdCount = extractCount - firstThirdCount - middleThirdCount

        var timestamps: [(start: CMTime, duration: CMTime)] = []

        // Helper to add timestamps for a section
        func addTimestamps(count: Int, sectionStart: TimeInterval, sectionEnd: TimeInterval) {
            guard count > 0 else { return }
            let sectionDuration = sectionEnd - sectionStart
            let step = sectionDuration / Double(count)

            for i in 0..<count {
                let startTime = sectionStart + (step * Double(i))
                timestamps.append((
                    start: CMTime(seconds: startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: extractDuration, preferredTimescale: 600)
                ))
            }
        }

        // Add timestamps for each section
        addTimestamps(count: firstThirdCount, sectionStart: skipStart, sectionEnd: firstThirdEnd)
        addTimestamps(count: middleThirdCount, sectionStart: firstThirdEnd, sectionEnd: secondThirdEnd)
        addTimestamps(count: lastThirdCount, sectionStart: secondThirdEnd, sectionEnd: totalDuration - skipEnd)

        // Sort by start time
        timestamps.sort { CMTimeCompare($0.start, $1.start) == -1 }

        logger.info("Calculated \(timestamps.count) extract timestamps")
        return timestamps
    }

    private func composeVideoSegments(
        asset: AVAsset,
        timestamps: [(start: CMTime, duration: CMTime)],
        extractDuration: TimeInterval,
        playbackSpeed: Double,
        includeAudio: Bool,
        video: VideoInput
    ) async throws -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix?) {
        logger.info("🎬 Starting composition with \(timestamps.count) segments, playback speed: \(playbackSpeed)x")
        let composition = AVMutableComposition()

        // Get asset duration for validation
        let assetDuration = try await asset.load(.duration)
        let assetDurationSeconds = CMTimeGetSeconds(assetDuration)
        logger.info("📹 Asset duration: \(assetDurationSeconds)s")

        // Add video track
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        logger.info("📹 Found \(videoTracks.count) video track(s)")

        guard let videoTrack = videoTracks.first else {
            logger.error("❌ No video tracks found in asset")
            throw PreviewError.noVideoTracks
        }

        // Log video track info
        let videoTrackDuration = try await videoTrack.load(.timeRange).duration
        logger.info("📹 Video track duration: \(CMTimeGetSeconds(videoTrackDuration))s")

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            logger.error("❌ Failed to create composition video track")
            throw PreviewError.compositionFailed("Failed to create composition video track", nil)
        }
        logger.info("✅ Created composition video track")

        // Add audio track if needed
        var compositionAudioTrack: AVMutableCompositionTrack?

        if includeAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            logger.info("🔊 Found \(audioTracks.count) audio track(s)")

            if let audioTrack = audioTracks.first {
                compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                logger.info("✅ Created composition audio track")
            } else {
                logger.warning("⚠️ Audio requested but no audio tracks found")
            }
        } else {
            logger.info("🔇 Audio disabled for this preview")
        }

        // Insert segments
        var insertTime = CMTime.zero
        let progressStep = 0.5 / Double(timestamps.count) // 0.2 to 0.7 range

        logger.info("🔧 Starting to insert \(timestamps.count) segments...")

        for (index, timestamp) in timestamps.enumerated() {
            // Check for cancellation
            if cancellationFlags[video.id] == true {
                logger.warning("⚠️ Composition cancelled at segment \(index + 1)")
                throw PreviewError.cancelled
            }

            // Calculate time range
            let startSeconds = CMTimeGetSeconds(timestamp.start)
            let durationSeconds = CMTimeGetSeconds(timestamp.duration)
            let timeRange = CMTimeRange(start: timestamp.start, duration: timestamp.duration)

            logger.debug("📍 Segment \(index + 1): start=\(startSeconds)s, duration=\(durationSeconds)s, insertAt=\(CMTimeGetSeconds(insertTime))s")

            // Validate time range is within asset bounds
            let endTime = CMTimeAdd(timestamp.start, timestamp.duration)
            if CMTimeCompare(endTime, assetDuration) > 0 {
                let error = "Time range exceeds asset duration: \(CMTimeGetSeconds(endTime))s > \(assetDurationSeconds)s"
                logger.error("❌ \(error)")
                throw PreviewError.compositionFailed(error, nil)
            }

            do {
                // Insert video segment
                logger.debug("  📹 Inserting video segment...")
                try compositionVideoTrack.insertTimeRange(
                    timeRange,
                    of: videoTrack,
                    at: insertTime
                )
                logger.debug("  ✅ Video segment inserted")

                // Insert audio segment if available
                if includeAudio, let compAudioTrack = compositionAudioTrack {
                    logger.debug("  🔊 Inserting audio segment...")
                    if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                        try compAudioTrack.insertTimeRange(
                            timeRange,
                            of: audioTrack,
                            at: insertTime
                        )
                        logger.debug("  ✅ Audio segment inserted")
                    }
                }

                // Apply time scaling if needed
                if playbackSpeed != 1.0 {
                    logger.debug("  ⚡ Applying time scaling: \(playbackSpeed)x")
                    let scaledDuration = CMTime(
                        seconds: extractDuration / playbackSpeed,
                        preferredTimescale: 600
                    )
                    let scaleRange = CMTimeRange(start: insertTime, duration: timestamp.duration)

                    logger.debug("    Scale range: start=\(CMTimeGetSeconds(scaleRange.start))s, duration=\(CMTimeGetSeconds(scaleRange.duration))s → \(CMTimeGetSeconds(scaledDuration))s")

                    compositionVideoTrack.scaleTimeRange(scaleRange, toDuration: scaledDuration)

                    if let compAudioTrack = compositionAudioTrack {
                        compAudioTrack.scaleTimeRange(scaleRange, toDuration: scaledDuration)
                    }

                    insertTime = CMTimeAdd(insertTime, scaledDuration)
                    logger.debug("  ✅ Time scaling applied, new insertTime: \(CMTimeGetSeconds(insertTime))s")
                } else {
                    insertTime = CMTimeAdd(insertTime, timestamp.duration)
                }

                // Report progress
                let progress = 0.2 + (progressStep * Double(index + 1))
                reportProgress(
                    for: video,
                    progress: progress,
                    status: .composing,
                    message: "Composing segment \(index + 1)/\(timestamps.count)"
                )

            } catch let error as NSError {
                let errorDetails = """
                ❌ Failed to insert segment \(index + 1)/\(timestamps.count)
                   Time range: \(startSeconds)s - \(startSeconds + durationSeconds)s (duration: \(durationSeconds)s)
                   Insert at: \(CMTimeGetSeconds(insertTime))s
                   Error domain: \(error.domain)
                   Error code: \(error.code)
                   Error description: \(error.localizedDescription)
                   User info: \(error.userInfo)
                """
                logger.error("\(errorDetails)")
                throw PreviewError.compositionFailed(
                    "Segment \(index + 1): \(error.localizedDescription)",
                    error
                )
            }
        }

        let finalDuration = CMTimeGetSeconds(insertTime)
        logger.info("✅ All segments inserted successfully. Final composition duration: \(finalDuration)s")

        // Create audio mix if we have audio
        var audioMix: AVMutableAudioMix?
        if let compAudioTrack = compositionAudioTrack {
            let params = AVMutableAudioMixInputParameters(track: compAudioTrack)
            params.trackID = compAudioTrack.trackID

            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        return (composition, audioMix)
    }

    private func exportComposition(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        config: PreviewConfiguration,
        video: VideoInput
    ) async throws -> URL {
        logger.info("🎞️ Starting export for \(video.title)")

        // Log composition details
        let compositionDuration = CMTimeGetSeconds(composition.duration)
        let videoTracks = composition.tracks(withMediaType: .video).count
        let audioTracks = composition.tracks(withMediaType: .audio).count
        logger.info("📊 Composition details:")
        logger.info("  - Duration: \(compositionDuration)s")
        logger.info("  - Video tracks: \(videoTracks)")
        logger.info("  - Audio tracks: \(audioTracks)")

        // Create output directory
        let outputDirectory = config.generateOutputDirectory(for: video)
        logger.info("📁 Output directory: \(outputDirectory.path)")

        if outputDirectory.startAccessingSecurityScopedResource() {
            defer { outputDirectory.stopAccessingSecurityScopedResource() }
        }
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info("✅ Output directory created/verified")
        } catch {
            logger.error("❌ Failed to create output directory: \(error.localizedDescription)")
            throw PreviewError.outputDirectoryCreationFailed(outputDirectory, error)
        }

        // Generate output URL
        let filename = config.generateFilename(for: video)
        let outputURL = outputDirectory.appendingPathComponent(filename)
        logger.info("📄 Output file: \(filename)")
        logger.info("📍 Full path: \(outputURL.path)")

        let didStartAccessing = outputURL.startAccessingSecurityScopedResource()

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            logger.info("🗑️ Removing existing file at output path")
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Create export session
        let preset = config.format.exportPreset(quality: config.compressionQuality)
        logger.info("⚙️ Export configuration:")
        logger.info("  - Preset: \(preset)")
        logger.info("  - Format: \(config.format.rawValue)")
        logger.info("  - File type: \(config.format.avFileType.rawValue)")
        logger.info("  - Quality: \(config.compressionQuality)")
        logger.info("  - Audio mix: \(audioMix != nil ? "enabled" : "disabled")")

        // Check compatible presets for this composition
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        logger.info("✅ Compatible presets for this composition: \(compatiblePresets.count)")
        logger.debug("  Presets: \(compatiblePresets.joined(separator: ", "))")

        if !compatiblePresets.contains(preset) {
            logger.warning("⚠️ Selected preset '\(preset)' is NOT in compatible presets list")
            logger.info("  Attempting anyway as AVFoundation may still support it...")
        } else {
            logger.info("✅ Selected preset '\(preset)' is compatible")
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: preset
        ) else {
            logger.error("❌ Failed to create AVAssetExportSession")
            logger.error("  - Preset: \(preset)")
            logger.error("  - Composition duration: \(compositionDuration)s")
            logger.error("  - Composition tracks: \(videoTracks) video, \(audioTracks) audio")
            throw PreviewError.encodingFailed("Failed to create export session with preset '\(preset)'", nil)
        }
        logger.info("✅ Export session created successfully")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = config.format.avFileType
        exportSession.audioMix = audioMix

        logger.info("🎬 Starting export...")

        // Export with progress tracking
        await exportSession.export()

        // Capture status and error to avoid data races
        let finalStatus = exportSession.status
        let finalError = exportSession.error

        logger.info("🎬 Export completed, checking status...")
        logger.info("  - Status: \(finalStatus.rawValue) (\(self.statusDescription(finalStatus)))")

        // Check for errors
        if let error = finalError {
            let nsError = error as NSError
            let errorDetails = """
            ❌ Export failed with error:
               Status: \(finalStatus.rawValue) (\(self.statusDescription(finalStatus)))
               Error domain: \(nsError.domain)
               Error code: \(nsError.code)
               Error description: \(nsError.localizedDescription)
               User info: \(nsError.userInfo)
               Output URL: \(outputURL.path)
               Preset: \(preset)
               File type: \(config.format.avFileType.rawValue)
            """
            logger.error("\(errorDetails)")

            if didStartAccessing {
                outputURL.stopAccessingSecurityScopedResource()
            }
            throw PreviewError.encodingFailed("Export failed", error)
        }

        guard finalStatus == .completed else {
            let errorDetails = """
            ❌ Export finished with non-completed status:
               Status: \(finalStatus.rawValue) (\(self.statusDescription(finalStatus)))
               Output URL: \(outputURL.path)
               Preset: \(preset)
               File type: \(config.format.avFileType.rawValue)
            """
            logger.error("\(errorDetails)")

            if didStartAccessing {
                outputURL.stopAccessingSecurityScopedResource()
            }
            throw PreviewError.encodingFailed(
                "Export finished with status: \(self.statusDescription(finalStatus))",
                nil
            )
        }

        // Verify output file exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            let fileSizeMB = Double(fileSize) / 1_048_576.0
            logger.info("✅ Export completed successfully")
            logger.info("  - Output: \(outputURL.lastPathComponent)")
            logger.info("  - Size: \(String(format: "%.2f", fileSizeMB)) MB")
        } else {
            logger.error("❌ Export reported success but file does not exist at: \(outputURL.path)")
        }

        if didStartAccessing {
            outputURL.stopAccessingSecurityScopedResource()
        }
        return outputURL
    }

    private func statusDescription(_ status: AVAssetExportSession.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .waiting: return "waiting"
        case .exporting: return "exporting"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func reportProgress(
        for video: VideoInput,
        progress: Double,
        status: PreviewGenerationStatus,
        message: String? = nil
    ) {
        let progressInfo = PreviewGenerationProgress(
            video: video,
            progress: progress,
            status: status,
            message: message
        )
        progressHandlers[video.id]?(progressInfo)
    }
}
