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
    private var progressTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Cleanup

    /// Cancel all progress tasks for a video
    private func cancelProgressTasks(for videoID: UUID) {
        progressTasks[videoID]?.cancel()
        progressTasks.removeValue(forKey: videoID)
    }

    /// Store a progress task for later cancellation
    private func storeProgressTask(_ task: Task<Void, Never>, for videoID: UUID) {
        // Cancel any existing progress task for this video
        progressTasks[videoID]?.cancel()
        progressTasks[videoID] = task
    }

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
            cancelProgressTasks(for: video.id)
        }

        // Report analyzing status
        reportProgress(for: video, progress: 0.0, status: .analyzing)

        do {
            let outputURL = try await PreviewGenerationLogic.generate(
                for: video,
                config: config,
                progressHandler: { [weak self] progress, status, url, message in
                    guard let self = self else { return }
                    let progressTask = Task { [weak self] in
                        guard let self = self else { return }
                        await self.reportProgress(for: video, progress: progress, status: status, outputURL: url, message: message)
                    }
                    Task { [weak self] in
                        await self?.storeProgressTask(progressTask, for: video.id)
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
        cancelProgressTasks(for: video.id)
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
            cancelProgressTasks(for: video.id)
        }

        // Report analyzing status
        reportProgress(for: video, progress: 0.0, status: .analyzing)

        do {
            let playerItem = try await PreviewGenerationLogic.generateComposition(
                for: video,
                config: config,
                progressHandler: { [weak self] progress, status, url, message in
                    guard let self = self else { return }
                    let progressTask = Task { [weak self] in
                        guard let self = self else { return }
                        await self.reportProgress(for: video, progress: progress, status: status, outputURL: url, message: message)
                    }
                    Task { [weak self] in
                        await self?.storeProgressTask(progressTask, for: video.id)
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
        // Cancel all progress tasks
        for task in progressTasks.values {
            task.cancel()
        }
        progressTasks.removeAll()
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
        
        // Get video duration for extract calculation
        let duration = try await asset.load(.duration)
        let videoDuration = CMTimeGetSeconds(duration)
        
        // Calculate parameters
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters(forVideoDuration: videoDuration)
        let extractCount = config.extractCount(forVideoDuration: videoDuration)
        
        progressHandler(0.1, .analyzing, nil, "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: extractCount,
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
        return try await exportComposition2(
            composition: videoComposition.composition,
            audioMix: videoComposition.audioMix,
            config: config,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
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
        
        // Get video duration for extract calculation
        let duration = try await asset.load(.duration)
        let videoDuration = CMTimeGetSeconds(duration)
        
        // Calculate parameters
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters(forVideoDuration: videoDuration)
        let extractCount = config.extractCount(forVideoDuration: videoDuration)
        
        progressHandler(0.1, .analyzing, nil, "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: extractCount,
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
        
        let playerItem = await AVPlayerItem(asset: composition)
        
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
        let (extractDuration, playbackSpeed) = config.calculateExtractParameters(forVideoDuration: durationSeconds)
        let extractCount = config.extractCount(forVideoDuration: durationSeconds)
        let minimumRequired = extractDuration * Double(extractCount)
        
        logger.info("📊 Extract parameters:")
        logger.info("  - Base extract count: \(config.baseExtractCount)")
        logger.info("  - Adjusted extract count: \(extractCount)")
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
        logger.debug("Starting composition with \(timestamps.count) segments, playback speed: \(playbackSpeed)x")
        let composition = AVMutableComposition()

        // Get asset duration for validation
        let assetDuration = try await asset.load(.duration)
        let assetDurationSeconds = CMTimeGetSeconds(assetDuration)

        // Load source tracks ONCE before the loop
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            logger.error("No video tracks found in asset")
            throw PreviewError.noVideoTracks
        }

        let audioTrack: AVAssetTrack? = includeAudio
            ? try await asset.loadTracks(withMediaType: .audio).first
            : nil

        if includeAudio && audioTrack == nil {
            logger.warning("Audio requested but no audio tracks found in asset")
        }

        // Create composition tracks
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            logger.error("Failed to create composition video track")
            throw PreviewError.compositionFailed("Failed to create composition video track", nil)
        }

        var compositionAudioTrack: AVMutableCompositionTrack?
        if audioTrack != nil {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        // Insert segments
        var insertTime = CMTime.zero
        let progressStep = 0.5 / Double(timestamps.count)

        for (index, timestamp) in timestamps.enumerated() {
            if cancellationCheck() {
                logger.warning("Composition cancelled at segment \(index + 1)")
                throw PreviewError.cancelled
            }

            let timeRange = CMTimeRange(start: timestamp.start, duration: timestamp.duration)
            let endTime = CMTimeAdd(timestamp.start, timestamp.duration)

            // Validate time range is within asset bounds
            if CMTimeCompare(endTime, assetDuration) > 0 {
                let error = "Time range exceeds asset duration: \(CMTimeGetSeconds(endTime))s > \(assetDurationSeconds)s"
                logger.error("\(error)")
                throw PreviewError.compositionFailed(error, nil)
            }

            do {
                // Insert video segment
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)

                // Insert audio segment from pre-loaded track
                if let srcAudio = audioTrack, let dstAudio = compositionAudioTrack {
                    try dstAudio.insertTimeRange(timeRange, of: srcAudio, at: insertTime)
                }

                // Apply time scaling on the COMPOSITION (scales all tracks atomically)
                if playbackSpeed != 1.0 {
                    let scaledDuration = CMTime(
                        seconds: extractDuration / playbackSpeed,
                        preferredTimescale: 600
                    )
                    let scaleRange = CMTimeRange(start: insertTime, duration: timestamp.duration)
                    composition.scaleTimeRange(scaleRange, toDuration: scaledDuration)
                    insertTime = CMTimeAdd(insertTime, scaledDuration)
                } else {
                    insertTime = CMTimeAdd(insertTime, timestamp.duration)
                }

                let progress = 0.2 + (progressStep * Double(index + 1))
                progressHandler(progress, .composing, nil, "Composing segment \(index + 1)/\(timestamps.count)")

            } catch let error as NSError {
                logger.error("Failed to insert segment \(index + 1)/\(timestamps.count): \(error.localizedDescription)")
                throw PreviewError.compositionFailed(
                    "Segment \(index + 1): \(error.localizedDescription)",
                    error
                )
            }
        }

        let finalDuration = CMTimeGetSeconds(insertTime)
        logger.info("All segments inserted. Final composition duration: \(finalDuration)s")

        // Validate segments on composition tracks
        if let videoSegments = compositionVideoTrack.segments {
            do {
                try compositionVideoTrack.validateSegments(videoSegments)
            } catch {
                logger.warning("Video track segments failed validation: \(error.localizedDescription)")
            }
        }
        if let compAudioTrack = compositionAudioTrack, let audioSegments = compAudioTrack.segments {
            do {
                try compAudioTrack.validateSegments(audioSegments)
            } catch {
                logger.warning("Audio track segments failed validation: \(error.localizedDescription)")
            }
        }

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
        logger.debug("📊 Composition details:")
        logger.debug("  - Duration: \(compositionDuration)s")
        logger.debug("  - Video tracks: \(videoTracks)")
        logger.debug("  - Audio tracks: \(audioTracks)")
        
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
        
        
        // Helper function to scale dimensions to a maximum resolution
        func scaleDimensions(width: Int, height: Int, maxHeight: Int) -> (width: Int, height: Int) {
            // Determine orientation
            let isPortrait = height > width
            
            // If already at or below target, return original dimensions
            if isPortrait && height <= maxHeight {
                return (width, height)
            } else if !isPortrait && width <= maxHeight {
                return (width, height)
            }
            
            // Scale down maintaining aspect ratio
            let aspectRatio = Double(width) / Double(height)
            
            if isPortrait {
                // For portrait videos, maxHeight is the limiting dimension
                let scaledHeight = maxHeight
                let scaledWidth = Int(round(Double(scaledHeight) * aspectRatio))
                return (scaledWidth, scaledHeight)
            } else {
                // For landscape videos, maxHeight becomes the limiting width
                let scaledWidth = maxHeight
                let scaledHeight = Int(round(Double(scaledWidth) / aspectRatio))
                return (scaledWidth, scaledHeight)
            }
        }
        
        let targetDimensions: (width: Int, height: Int)
        
        if quality == 1.0 {
            // Maximum resolution: 4K (3840x2160 for landscape, 2160x3840 for portrait)
            targetDimensions = scaleDimensions(width: width, height: height, maxHeight: 2160)
            videoConfig = .codec(.hevc, width: targetDimensions.width, height: targetDimensions.height)
            audioBitrate = 128_000  // 128 kbps
        } else if quality == 0.75 {
            // Maximum resolution: 4K (3840x2160 for landscape, 2160x3840 for portrait)
            targetDimensions = scaleDimensions(width: width, height: height, maxHeight: 2160)
            videoConfig = .codec(.h264(.highAuto), width: targetDimensions.width, height: targetDimensions.height)
            audioBitrate = 128_000  // 128 kbps
        } else if quality == 0.5 {
            // Maximum resolution: 1080p (1920x1080 for landscape, 1080x1920 for portrait)
            targetDimensions = scaleDimensions(width: width, height: height, maxHeight: 2160)
            videoConfig = .codec(.h264(.mainAuto), width: targetDimensions.width, height: targetDimensions.height)
            audioBitrate = 128_000  // 128 kbps
        } else if quality == 0.25 {
            // Maximum resolution: 720p (1280x720 for landscape, 720x1280 for portrait)
            targetDimensions = scaleDimensions(width: width, height: height, maxHeight: 2160)
            videoConfig = .codec(.h264(.baselineAuto), width: targetDimensions.width, height: targetDimensions.height)
            audioBitrate = 128_000  // 128 kbps
        } else {
            // Maximum resolution: 540p (960x540 for landscape, 540x960 for portrait)
            targetDimensions = scaleDimensions(width: width, height: height, maxHeight: 2160)
            videoConfig = .codec(.h264(.baselineAuto), width: targetDimensions.width, height: targetDimensions.height)
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
    @MainActor
    private static func exportComposition2(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        config: PreviewConfiguration,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        logger.info("🎞️ Starting export for \(video.title)")

        // ✅ FIX 1: Configure audio session (iOS only)
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            logger.debug("✅ Audio session configured for export")
        } catch {
            logger.warning("⚠️ Failed to configure audio session: \(error.localizedDescription)")
        }
        #endif

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

        // ✅ FIX 2: Proper security-scoped resource handling with defer
        let didStartAccessingDir = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingDir {
                outputDirectory.stopAccessingSecurityScopedResource()
            }
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

        // ✅ FIX 3: Proper security-scoped resource handling for output file
        let didStartAccessingFile = outputURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingFile {
                outputURL.stopAccessingSecurityScopedResource()
            }
        }

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
  //      exportSession.audioMix = audioMix
        exportSession.allowsParallelizedExport = true
        exportSession.shouldOptimizeForNetworkUse = true
        logger.info("🎬 Starting export...")

        // Initial progress
        progressHandler(0, .queued, nil, "Waiting")

        // ✅ FIX 4: Proper progress monitoring with cleanup
        let progressMonitor = Task {
            for await state in exportSession.states(updateInterval: 5) {
                // Check for task cancellation
                if Task.isCancelled {
                    logger.debug("Progress monitor cancelled")
                    return
                }

                switch state {
                case .pending:
                    progressHandler(0, .queued, nil, "Pending")

                case .waiting:
                    progressHandler(0, .queued, nil, "Waiting")

                case let .exporting(progress):
                    let progressValue = progress.fractionCompleted
                    let exportProgress = 0.3 + (progressValue * 0.7)
                    progressHandler(
                        exportProgress,
                        .encoding,
                        nil,
                        "Encoding: \(Int(progressValue * 100))%"
                    )

                    // ✅ FIX 5: Exit when export completes (use return, not break)
                    if progressValue >= 0.999 {
                        logger.debug("Progress reached 100%, exiting monitor")
                        return
                    }

                @unknown default:
                    break
                }
            }
        }

        // Ensure progress monitor is cleaned up
        defer {
            progressMonitor.cancel()
        }

        // ✅ FIX 6: Check for cancellation before starting export
        if cancellationCheck() {
            logger.warning("Export cancelled before starting")
            throw PreviewError.cancelled
        }

        // ✅ FIX 7: Cancellation monitoring during export
        let cancellationMonitor = Task {
            while !Task.isCancelled {
                if cancellationCheck() {
                    logger.warning("Cancellation requested, cancelling export")
                    exportSession.cancelExport()
                    return
                }
                // Check every 100ms
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Ensure cancellation monitor is cleaned up
        defer {
            cancellationMonitor.cancel()
        }

        // Perform the export with error handling
        do {
            try await exportSession.export(to: outputURL, as: config.format.avFileType)
        } catch {
            logger.error("❌ Export threw error: \(error.localizedDescription)")

            // Check if it was a cancellation
            if cancellationCheck() {
                throw PreviewError.cancelled
            }

            throw PreviewError.encodingFailed("Export failed", error)
        }

        // Capture status and error to avoid data races
        let finalStatus = exportSession.status
        let finalError = exportSession.error

        logger.info("🎬 Export completed, checking status...")
        logger.info("  - Status: \(finalStatus.rawValue) (\(self.statusDescription(finalStatus)))")

        // ✅ FIX 8: Check for cancellation after export
        if cancellationCheck() {
            logger.warning("Export was cancelled")
            throw PreviewError.cancelled
        }

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
            throw PreviewError.encodingFailed("Export completed but output file not found", nil)
        }

        return outputURL
    }

}
