//
//  PreviewVideoGenerator.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

import Foundation
import AVFoundation
import OSLog
import UniformTypeIdentifiers
import SJSAssetExportSession

/// Thread-safe cancellation token
class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
    
    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

/// Actor responsible for generating preview videos from source videos
@available(macOS 26, iOS 26, *)
public actor PreviewVideoGenerator {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.mosaickit", category: "PreviewVideoGenerator")
    private var progressHandlers: [UUID: @Sendable (PreviewGenerationProgress) -> Void] = [:]
    private var cancellationTokens: [UUID: CancellationToken] = [:]

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
        
        // Create cancellation token
        let token = CancellationToken()
        cancellationTokens[video.id] = token
        
        defer {
            cancellationTokens.removeValue(forKey: video.id)
        }
        
        // Report analyzing status
        reportProgress(for: video, progress: 0.0, status: .analyzing)
        
        do {
            let outputURL = try await PreviewGenerationLogic.generate(
                for: video,
                config: config,
                progressHandler: { [weak self] progress, status, url, message in
                    Task { [weak self] in
                        await self?.reportProgress(for: video, progress: progress, status: status, outputURL: url, message: message)
                    }
                },
                cancellationCheck: { [token] in
                    token.isCancelled
                }
            )
            
            // Report completion
            reportProgress(for: video, progress: 1.0, status: .completed)
            logger.info("Preview generation completed: \(outputURL.lastPathComponent)")
            
            return outputURL
        } catch {
            if token.isCancelled {
                throw PreviewError.cancelled
            }
            throw error
        }
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
        cancellationTokens[video.id]?.cancel()
    }

    /// Generate a preview composition without exporting to file (for video player playback)
    /// - Parameters:
    ///   - video: The source video
    ///   - config: Preview configuration
    /// - Returns: AVPlayerItem configured with the preview composition
    public func generateComposition(
        for video: VideoInput,
        config: PreviewConfiguration
    ) async throws -> AVPlayerItem {
        logger.info("Starting preview composition generation for \(video.title)")

        // Create cancellation token
        let token = CancellationToken()
        cancellationTokens[video.id] = token

        defer {
            cancellationTokens.removeValue(forKey: video.id)
        }

        // Report analyzing status
        reportProgress(for: video, progress: 0.0, status: .analyzing)

        do {
            let playerItem = try await PreviewGenerationLogic.generateComposition(
                for: video,
                config: config,
                progressHandler: { [weak self] progress, status, url, message in
                    Task { [weak self] in
                        await self?.reportProgress(for: video, progress: progress, status: status, outputURL: url, message: message)
                    }
                },
                cancellationCheck: { [token] in
                    token.isCancelled
                }
            )

            // Report completion
            reportProgress(for: video, progress: 1.0, status: .completed)
            logger.info("Preview composition generated successfully")

            return playerItem
        } catch {
            if token.isCancelled {
                throw PreviewError.cancelled
            }
            throw error
        }
    }

    /// Cancel all active generations
    public func cancelAll() {
        logger.info("Cancelling all preview generations")
        for token in cancellationTokens.values {
            token.cancel()
        }
    }

    // MARK: - Private Methods

    private func reportProgress(
        for video: VideoInput,
        progress: Double,
        status: PreviewGenerationStatus,
        outputURL: URL? = nil,
        message: String? = nil
    ) {
        let progressInfo = PreviewGenerationProgress(
            video: video,
            progress: progress,
            status: status,
            outputURL: outputURL,
            message: message
        )
        progressHandlers[video.id]?(progressInfo)
    }
}

/// Logic for preview generation, isolated to MainActor to ensure AVFoundation safety
@available(macOS 26, iOS 26, *)
@MainActor
struct PreviewGenerationLogic {
    private static let logger = Logger(subsystem: "com.mosaickit", category: "PreviewGenerationLogic")
    
    static func generate(
        for video: VideoInput,
        config: PreviewConfiguration,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        logger.info("Starting preview generation logic for \(video.title)")
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        progressHandler(0.0, .analyzing, nil, nil)
        
        // Load asset
        let asset = AVURLAsset(url: video.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        
        // Validate
        try await validateVideo(asset: asset, video: video, config: config)
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        // Calculate parameters
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters()
        
        progressHandler(0.1, .analyzing, nil, "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: config.extractCount,
            extractDuration: extractDuration
        )
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        // Compose
        progressHandler(0.2, .extracting, nil, "Extracting \(timestamps.count) segments...")
        let videoComposition = try await composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        // Export
        progressHandler(0.3, .encoding, nil, "Encoding preview video...")
        let outputURL = try await exportComposition(
            composition: videoComposition.composition,
            audioMix: videoComposition.audioMix,
            config: config,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        
        return outputURL
    }

    /// Generate a preview composition without exporting (for video player playback)
    static func generateComposition(
        for video: VideoInput,
        config: PreviewConfiguration,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> AVPlayerItem {
        logger.info("Starting preview composition generation logic for \(video.title)")

        if cancellationCheck() { throw PreviewError.cancelled }

        progressHandler(0.0, .analyzing, nil, nil)

        // Load asset
        let asset = AVURLAsset(url: video.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // Validate
        try await validateVideo(asset: asset, video: video, config: config)

        if cancellationCheck() { throw PreviewError.cancelled }

        // Calculate parameters
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters()

        progressHandler(0.1, .analyzing, nil, "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: config.extractCount,
            extractDuration: extractDuration
        )

        if cancellationCheck() { throw PreviewError.cancelled }

        // Compose
        progressHandler(0.2, .extracting, nil, "Extracting \(timestamps.count) segments...")
        let videoComposition = try await composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )

        if cancellationCheck() { throw PreviewError.cancelled }

        // Create player item from composition
        progressHandler(0.8, .composing, nil, "Creating player item...")

        // Note: AVMutableComposition is not Sendable in Swift 6, but it's safe to use here
        // because it's created locally in this actor and won't be accessed concurrently
        nonisolated(unsafe) let composition = videoComposition.composition
        nonisolated(unsafe) let audioMix = videoComposition.audioMix

        let playerItem = AVPlayerItem(asset: composition)

        // Apply audio mix if available
        if let mix = audioMix {
            playerItem.audioMix = mix
        }

        progressHandler(1.0, .completed, nil, "Composition ready for playback")
        logger.info("Preview composition created successfully")

        return playerItem
    }

    private static func validateVideo(asset: AVAsset, video: VideoInput, config: PreviewConfiguration) async throws {
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
    
    private static func calculateExtractTimestamps(
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
        let firstThirdCount = Int(Double(extractCount) * 0.2)
        let middleThirdCount = Int(Double(extractCount) * 0.6)
        let lastThirdCount = extractCount - firstThirdCount - middleThirdCount

        var timestamps: [(start: CMTime, duration: CMTime)] = []

        // Helper to add timestamps for a section
        func addTimestamps(count: Int, sectionStart: TimeInterval, sectionEnd: TimeInterval) {
            guard count > 0 else { return }
            let sectionDuration = sectionEnd - sectionStart
            let step = sectionDuration / Double(count)

            for i in 0..<count {
                let startTime = sectionStart + (step * Double(i))
                // Ensure the extract fits in the video
                let maxStartTime = totalDuration - extractDuration
                let clampedStartTime = min(startTime, maxStartTime)
                
                timestamps.append((
                    start: CMTime(seconds: clampedStartTime, preferredTimescale: 600),
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
    
    private static func composeVideoSegments(
        asset: AVAsset,
        timestamps: [(start: CMTime, duration: CMTime)],
        extractDuration: TimeInterval,
        playbackSpeed: Double,
        includeAudio: Bool,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
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

            if !audioTracks.isEmpty {
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
            if cancellationCheck() {
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
                logger.debug("  - TimeRange: \(startSeconds)s, duration: \(durationSeconds)s")
                logger.debug("  - InsertAt: \(CMTimeGetSeconds(insertTime))s")
                
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
                progressHandler(
                    progress,
                    .composing,
                    nil,
                    "Composing segment \(index + 1)/\(timestamps.count)"
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
    
    private static func exportComposition(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        config: PreviewConfiguration,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
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

        // Get original video dimensions from composition
        guard let compositionVideoTrack = composition.tracks(withMediaType: .video).first else {
            logger.error("❌ No video tracks in composition")
            throw PreviewError.noVideoTracks
        }

        let naturalSize = try await compositionVideoTrack.load(.naturalSize)
        let originalWidth = Int(naturalSize.width)
        let originalHeight = Int(naturalSize.height)
        logger.info("📐 Original dimensions: \(originalWidth)x\(originalHeight)")

        // Create output directory
        let outputDirectory = config.generateOutputDirectory(for: video)
        logger.info("📁 Output directory: \(outputDirectory.path)")

        if outputDirectory.startAccessingSecurityScopedResource() {
            outputDirectory.stopAccessingSecurityScopedResource()
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

        // Create export session with SJSAssetExportSession
        let exporter = ExportSession()

        // Determine video settings based on quality, using original dimensions
        let (videoConfig, audioBitrate) = videoSettings(
            for: config.compressionQuality,
            format: config.format,
            width: originalWidth,
            height: originalHeight
        )

        logger.info("⚙️ Export configuration:")
        logger.info("  - Format: \(config.format.rawValue)")
        logger.info("  - Quality: \(config.compressionQuality)")
        logger.info("  - Audio bitrate: \(audioBitrate) bps")
        logger.info("  - Audio mix: \(audioMix != nil ? "enabled" : "disabled")")

        logger.info("🎬 Starting export with progress tracking...")

        // Start progress monitoring task
        let progressTask = Task {
            for await progress in exporter.progressStream {
                // Check for cancellation
                if cancellationCheck() {
                    break
                }

                // Map export progress from 0.7-1.0 range
                // Export progress goes from 0-1, we map it to 0.7-1.0
                let progressValue = Double(progress)
                let exportProgress = 0.3 + (progressValue * 0.7)
                progressHandler(
                    exportProgress,
                    .encoding,
                    nil,
                    "Encoding: \(Int(progressValue * 100))%"
                )
            //    logger.debug("Export progress: \(Int(progressValue * 100))%")
                if progressValue == 1.0 {
                    return true
                }
            }
            return true
        }

        // Perform the export
        do {
            // Note: AVMutableComposition is not Sendable in Swift 6, but it's safe to use here
            // because it's created locally in this actor and won't be accessed concurrently
            // We use nonisolated(unsafe) to bypass the Sendable check
            nonisolated(unsafe) let compositionAsset = composition as AVAsset

            try await exporter.export(
                asset: compositionAsset,
                audio: .format(.aac),
                video: videoConfig,
                to: outputURL,
                as: config.format.avFileType
            )

            // Wait for progress task to complete
            _ = await progressTask.value

            // Check for cancellation
            if cancellationCheck() {
                throw PreviewError.cancelled
            }

            logger.info("🎬 Export completed successfully")

            // Report final completion status
            progressHandler(
                0.9,
                .saving,
                nil,
                "Export complete"
            )

            // Verify output file exists
            if FileManager.default.fileExists(atPath: outputURL.path) {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                let fileSizeMB = Double(fileSize) / 1_048_576.0
                logger.info("  - Output: \(outputURL.lastPathComponent)")
                logger.info("  - Size: \(String(format: "%.2f", fileSizeMB)) MB")
            } else {
                progressHandler(
                    1.0,
                    .failed,
                    nil,
                    "Could not saved"
                )
                logger.error("❌ Export completed but file does not exist at: \(outputURL.path)")
            }

            if didStartAccessing {
                outputURL.stopAccessingSecurityScopedResource()
            }
            progressHandler(
                1.0,
                .completed,
                outputURL,
                "Export saved"
            )
            return outputURL

        } catch {
            // Cancel progress monitoring
            progressTask.cancel()

            logger.error("❌ Export failed with error: \(error.localizedDescription)")

            if didStartAccessing {
                outputURL.stopAccessingSecurityScopedResource()
            }
            progressHandler(
                1.0,
                .failed,
                nil,
                error.localizedDescription
            )
            throw PreviewError.encodingFailed("Export failed", error)
        }
    }
    
    /// Determine video and audio settings based on quality level and original dimensions
    private static func videoSettings(
        for quality: Double,
        format: VideoFormat,
        width: Int,
        height: Int
    ) -> (video: VideoOutputSettings, audioBitrate: Int) {
        // Use original dimensions and adjust codec/bitrate based on quality
        // Quality ranges determine codec and bitrate, but dimensions stay original

        let videoConfig: VideoOutputSettings
        let audioBitrate: Int

        // Calculate bitrate based on resolution and quality
        // Base formula: pixels * quality_multiplier
        let totalPixels = width * height
        let pixelMultiplier: Double

        if quality == 1.0 {
            // Highest quality - HEVC with high bitrate
            pixelMultiplier = 0.15 // ~35 Mbps for 4K
            videoConfig = .codec(.hevc, width: width, height: height)
               // .fps(30)
                .bitrate(Int(Double(totalPixels) * pixelMultiplier))
                .color(.sdr)
            audioBitrate = 160_000 // 256 kbps
        } else if quality == 0.75 {
            // High quality - HEVC with medium-high bitrate
            pixelMultiplier = 0.08 // ~10 Mbps for 1080p
            videoConfig = .codec(.hevc, width: width, height: height)
                .fps(30)
                .bitrate(Int(Double(totalPixels) * pixelMultiplier))
                .color(.sdr)
            audioBitrate = 160_000  // 192 kbps
        } else if quality == 0.5 {
            // Medium quality - H.264 with medium bitrate
            pixelMultiplier = 0.06 // ~8 Mbps for 1080p
            videoConfig = .codec(.h264, width: width, height: height)
                //.fps(30)
                .bitrate(Int(Double(totalPixels) * pixelMultiplier))
                .color(.sdr)
            audioBitrate = 160_000 // 160 kbps
        } else if quality == 0.25 {
            // Medium quality - H.264 with medium bitrate
            pixelMultiplier = 0.04 // ~8 Mbps for 1080p
            videoConfig = .codec(.h264, width: width, height: height)
                //.fps(30)
                .bitrate(Int(Double(totalPixels) * pixelMultiplier))
                .color(.sdr)
            audioBitrate = 160_000 // 160 kbps
        } else
        {
            // Lower quality - H.264 with lower bitrate
            pixelMultiplier = 0.02 // ~5 Mbps for 1080p
            videoConfig = .codec(.h264, width: width/2 , height: height/2)
               // .fps(30)
                .bitrate(Int(Double(totalPixels) * pixelMultiplier))
                .color(.sdr)
            audioBitrate = 128_000  // 128 kbps
        }
        return (videoConfig, audioBitrate)
    }

    private static func statusDescription(_ status: AVAssetExportSession.Status) -> String {
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
}
