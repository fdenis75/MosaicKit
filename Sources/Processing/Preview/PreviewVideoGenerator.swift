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

/// Thread-safe tracker for the last time export progress changed.
/// Used to detect stalled exports that stop making forward progress.
class ExportProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastProgressTime: Date = Date()
    private var _lastProgressValue: Double = -1

    /// Record that progress changed. Only updates the timestamp when the value actually moves.
    func recordProgress(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        if value != _lastProgressValue {
            _lastProgressValue = value
            _lastProgressTime = Date()
        }
    }

    /// Seconds since the last time progress actually changed.
    var secondsSinceLastProgress: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(_lastProgressTime)
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
            reportProgress(for: video, progress: 1.0, status: .completed,outputURL: outputURL)
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
        progressHandler(0.2, .composing, nil, "Composing \(timestamps.count) segments...")
        let videoComposition = try await composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            maxResolution: config.exportMaxResolution,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        // Export — route based on configuration
        progressHandler(0.3, .encoding, nil, "Encoding preview video...")
        let returnURL: URL
        let error: Error
        if config.useNativeExport {
            do {
                returnURL = try await exportWithNativeSession(
                composition: videoComposition.composition,
                audioMix: videoComposition.audioMix,
                videoComposition: videoComposition.videoComposition,
                config: config,
                video: video,
                progressHandler: progressHandler,
                cancellationCheck: cancellationCheck
            )
                print("awaiting return of native export")
                return returnURL
            }
           
            
        } else {
            do {
                returnURL =  try await exportWithSJSSession(
                    composition: videoComposition.composition,
                    audioMix: videoComposition.audioMix,
                    videoComposition: videoComposition.videoComposition,
                    config: config,
                    video: video,
                    progressHandler: progressHandler,
                    cancellationCheck: cancellationCheck
                )
                
                print("awaiting return of native export")
                
                return returnURL
            }
        }
            
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
        progressHandler(0.2, .composing, nil, "Composing \(timestamps.count) segments...")
        let compositionResult = try await composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            maxResolution: config.exportMaxResolution,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        // Create player item from composition
        progressHandler(0.8, .composing, nil, "Creating player item...")
        
        // Note: AVMutableComposition is not Sendable in Swift 6, but it's safe to use here
        // because it's created locally and won't be accessed concurrently after this point
        nonisolated(unsafe) let sendableComposition = compositionResult.composition
        nonisolated(unsafe) let audioMix = compositionResult.audioMix
        nonisolated(unsafe) let sendableVideoComp = compositionResult.videoComposition
        
        let playerItem = await AVPlayerItem(asset: sendableComposition)
        
        // Apply video composition for scaling
        if let vc = sendableVideoComp {
            playerItem.videoComposition = vc
        }
        
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
        
        // Deduplicate timestamps that were clamped to the same start time
        var deduplicated: [(start: CMTime, duration: CMTime)] = []
        for ts in timestamps {
            if let last = deduplicated.last,
               abs(CMTimeGetSeconds(ts.start) - CMTimeGetSeconds(last.start)) < 0.01 {
                // Skip duplicate — timestamps clamped to maxStartTime
                continue
            }
            deduplicated.append(ts)
        }
        
        if deduplicated.count < timestamps.count {
            logger.info("Deduplicated timestamps: \(timestamps.count) -> \(deduplicated.count)")
        }
        
        logger.info("Calculated \(deduplicated.count) extract timestamps")
        return deduplicated
    }
    
    private static func composeVideoSegments(
        asset: AVAsset,
        timestamps: [(start: CMTime, duration: CMTime)],
        extractDuration: TimeInterval,
        playbackSpeed: Double,
        includeAudio: Bool,
        maxResolution: ExportMaxResolution?,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix?, videoComposition: AVMutableVideoComposition?) {
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
        var skippedSegments = 0
        
        for (index, timestamp) in timestamps.enumerated() {
            if cancellationCheck() {
                logger.warning("Composition cancelled at segment \(index + 1)")
                throw PreviewError.cancelled
            }
            
            let timeRange = CMTimeRange(start: timestamp.start, duration: timestamp.duration)
            let endTime = CMTimeAdd(timestamp.start, timestamp.duration)
            
            // Validate time range is within asset bounds — skip if out of range
            if CMTimeCompare(endTime, assetDuration) > 0 {
                logger.warning("Segment \(index + 1) exceeds asset duration (\(CMTimeGetSeconds(endTime))s > \(assetDurationSeconds)s), skipping")
                skippedSegments += 1
                continue
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
                logger.warning("Failed to insert segment \(index + 1)/\(timestamps.count): \(error.localizedDescription), skipping")
                skippedSegments += 1
            }
        }
        
        // Ensure we have at least some segments
        if skippedSegments > 0 {
            logger.info("Skipped \(skippedSegments)/\(timestamps.count) segments")
        }
        let insertedCount = timestamps.count - skippedSegments
        guard insertedCount > 0 else {
            throw PreviewError.compositionFailed("All \(timestamps.count) segments failed to insert", nil)
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
        
        // Build video composition for scaling if maxResolution requires downscaling
        var videoComp: AVMutableVideoComposition?
        if let maxRes = maxResolution,
           let compVideoTrack = composition.tracks(withMediaType: .video).first {
            let naturalSize = try await compVideoTrack.load(.naturalSize)
            let preferredTransform = try await compVideoTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            let sourceWidth = abs(transformedSize.width)
            let sourceHeight = abs(transformedSize.height)
            
            let targetMaxWidth = CGFloat(maxRes.maxWidth)
            let targetMaxHeight = CGFloat(maxRes.maxHeight)
            
            // Only downscale — never upscale
            if sourceWidth > targetMaxWidth || sourceHeight > targetMaxHeight {
                let scaleX = targetMaxWidth / sourceWidth
                let scaleY = targetMaxHeight / sourceHeight
                let scale = min(scaleX, scaleY)
                
                let renderWidth = (sourceWidth * scale).rounded(.down)
                let renderHeight = (sourceHeight * scale).rounded(.down)
                let renderSize = CGSize(width: renderWidth, height: renderHeight)
                
                let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
                let finalTransform = preferredTransform.concatenating(scaleTransform)
                
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
                layerInstruction.setTransform(finalTransform, at: .zero)
                
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
                instruction.layerInstructions = [layerInstruction]
                
                let nominalFrameRate = try await compVideoTrack.load(.nominalFrameRate)
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominalFrameRate > 0 ? nominalFrameRate : 30))
                vc.instructions = [instruction]
                videoComp = vc
                
                logger.info("Scaling composition from \(Int(sourceWidth))x\(Int(sourceHeight)) to \(Int(renderWidth))x\(Int(renderHeight))")
            }
        }
        
        return (composition, audioMix, videoComp)
    }
    
    /// Export using SJSAssetExportSession (custom exporter with fine-grained codec/bitrate control)
    private static func exportWithSJSSession(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        videoComposition: AVMutableVideoComposition?,
        config: PreviewConfiguration,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        logger.info("Starting SJS export for \(video.title)")
        
        // Get original video dimensions from composition
        guard let compositionVideoTrack = composition.tracks(withMediaType: .video).first else {
            throw PreviewError.noVideoTracks
        }
        
        let naturalSize = try await compositionVideoTrack.load(.naturalSize)
        let originalWidth = Int(naturalSize.width)
        let originalHeight = Int(naturalSize.height)
        
        // Prepare output URL
        let outputURL = try prepareOutputURL(config: config, video: video)
        
        let didStartAccessing = outputURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                outputURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        var renderSize: CGSize = naturalSize
        if let maxRes = config.exportMaxResolution,
           let compVideoTrack = composition.tracks(withMediaType: .video).first {
            let naturalSize = try await compVideoTrack.load(.naturalSize)
            let preferredTransform = try await compVideoTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            let sourceWidth = abs(transformedSize.width)
            let sourceHeight = abs(transformedSize.height)
            renderSize = CGSize(width: sourceWidth, height: sourceHeight)
            let targetMaxWidth = CGFloat(maxRes.maxWidth)
            let targetMaxHeight = CGFloat(maxRes.maxHeight)
            
            // Only downscale — never upscale
            if sourceWidth > targetMaxWidth || sourceHeight > targetMaxHeight {
                let scaleX = targetMaxWidth / sourceWidth
                let scaleY = targetMaxHeight / sourceHeight
                let scale = min(scaleX, scaleY)
                
                let renderWidth = (sourceWidth * scale).rounded(.down)
                let renderHeight = (sourceHeight * scale).rounded(.down)
                renderSize = CGSize(width: renderWidth, height: renderHeight)
            }
        }
            // Create export session with SJSAssetExportSession
            let exporter = ExportSession()
            
            // Determine video settings based on quality, using original dimensions
            let (videoConfig, audioBitrate) = videoSettings(
                for: config.compressionQuality,
                format: config.format,
                presetname: config.sJSExportPresetName,
                exportMaxResolution: config.exportMaxResolution ?? ._1080p,
                width: originalWidth,
                height: originalHeight,
                renderSize: renderSize
            )
            
            logger.info("SJS export: format=\(config.format.rawValue), q.uality=, audioBitrate=\(audioBitrate)")
            
            // Stall detection: cancel if no progress for 60 seconds
            let stallTimeout: TimeInterval = 60
            let progressTracker = ExportProgressTracker()
            progressTracker.recordProgress(0)
            let stallDetected = CancellationToken()
            
            // Start progress monitoring task
            let progressTask = Task {
                for await progress in exporter.progressStream {
                    if cancellationCheck() { break }
                    let progressValue = Double(progress)
                    progressTracker.recordProgress(progressValue)
                    let exportProgress = 0.3 + (progressValue * 0.7)
                    progressHandler(exportProgress, .encoding, nil, "Encoding: \(Int(progressValue * 100))%")
                    if progressValue >= 1.0 { return }
                }
            }
            
            // Stall + cancellation monitor for SJS export
            let stallMonitor = Task {
                while !Task.isCancelled {
                    if cancellationCheck() { break }
                    let elapsed = progressTracker.secondsSinceLastProgress
                    if elapsed >= stallTimeout {
                        logger.error("SJS export stalled: no progress for \(Int(elapsed))s, cancelling")
                        stallDetected.cancel()
                        progressTask.cancel()
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // check every 1s
                }
            }
            defer { stallMonitor.cancel() }
            
            // Perform the export
            do {
                nonisolated(unsafe) let compositionAsset = composition as AVAsset
                
                if let vc = videoComposition {
                    // Use the raw-settings overload so we can pass our custom video composition for scaling
                    nonisolated(unsafe) let sendableVC = vc as AVVideoComposition
                    try await exporter.export(
                        asset: compositionAsset,
                        audioOutputSettings: AudioOutputSettings.default.settingsDictionary,
                        videoOutputSettings: videoConfig.settingsDictionary,
                        composition: sendableVC,
                        to: outputURL,
                        as: config.format.avFileType
                    )
                } else {
                    try await exporter.export(
                        asset: compositionAsset,
                        audio: .default,
                        video: videoConfig,
                        to: outputURL,
                        as: config.format.avFileType
                    )
                }
                
                progressTask.cancel()
                
                if stallDetected.isCancelled {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
                }
                
                if cancellationCheck() {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw PreviewError.cancelled
                }
                
                // Verify output file exists
                guard FileManager.default.fileExists(atPath: outputURL.path) else {
                    throw PreviewError.encodingFailed("Export completed but output file not found", nil)
                }
                
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                logger.info("SJS export completed: \(outputURL.lastPathComponent) (\(String(format: "%.2f", Double(fileSize) / 1_048_576.0)) MB)")
                
                progressHandler(1.0, .completed, outputURL, "Export saved")
                return outputURL
                
            } catch {
                progressTask.cancel()
                // Clean up partial output file on failure
                try? FileManager.default.removeItem(at: outputURL)
                if stallDetected.isCancelled {
                    logger.error("SJS export stalled and was cancelled")
                    throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
                }
                logger.error("SJS export failed: \(error.localizedDescription)")
                progressHandler(1.0, .failed, nil, error.localizedDescription)
                throw PreviewError.encodingFailed("Export failed", error)
            }
        }
    
        
        /// Prepare the output URL: create the output directory and return the full file URL
        private static func prepareOutputURL(config: PreviewConfiguration, video: VideoInput) throws -> URL {
            let outputDirectory = config.generateOutputDirectory(for: video)
            
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
            } catch {
                throw PreviewError.outputDirectoryCreationFailed(outputDirectory, error)
            }
            
            let filename = config.generateFilename(for: video)
            return outputDirectory.appendingPathComponent(filename)
        }
        
        /// Determine video and audio settings based on quality level and original dimensions
        private static func videoSettings(
            for quality: Double,
            format: VideoFormat,
            presetname: SjSExportPreset?,
            exportMaxResolution: ExportMaxResolution,
            width: Int,
            height: Int,
            renderSize: CGSize
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
            
            if presetname != nil {
                //targetDimensions = scaleDimensions(width: width, height: height, maxHeight: exportMaxResolution.maxHeight)
                videoConfig = .codec(presetname?.SJSCodec ?? .hevc, width: Int(renderSize.width), height: Int(renderSize.height))
                audioBitrate = 128_000  // 128 kbps
                return (videoConfig, audioBitrate)
            }else {
                
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
                    targetDimensions = scaleDimensions(width: width, height: height, maxHeight: 1920)
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
    /// Export using AVAssetExportSession (Apple's native preset-based exporter)
    /// @MainActor ensures exportSession and its Task closures share the same isolation,
    /// avoiding 'sending' parameter errors for the non-Sendable AVAssetExportSession.
    @MainActor
    private static func exportWithNativeSession(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        videoComposition: AVMutableVideoComposition?,
        config: PreviewConfiguration,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        logger.info("Starting native export for \(video.title)")

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.warning("Failed to configure audio session: \(error.localizedDescription)")
        }
        #endif

        // Prepare output URL
        let outputURL = try prepareOutputURL(config: config, video: video)

        let didStartAccessingFile = outputURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingFile {
                outputURL.stopAccessingSecurityScopedResource()
            }
        }

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Use the effective preset (explicit or derived from quality)
        let preset = config.effectiveExportPreset
        logger.info("Native export: preset=\(preset), format=\(config.format.rawValue), quality=\(config.compressionQuality)")

        // Check compatible presets
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        if !compatiblePresets.contains(preset) {
            logger.warning("Preset '\(preset)' not in compatible presets, attempting anyway")
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: preset
        ) else {
            throw PreviewError.encodingFailed("Failed to create export session with preset '\(preset)'", nil)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = config.format.avFileType
        exportSession.allowsParallelizedExport = true
        exportSession.shouldOptimizeForNetworkUse = true

        // Apply video composition for resolution scaling
        if let vc = videoComposition {
            exportSession.videoComposition = vc
        }

        // Stall detection: cancel if no progress for 60 seconds
        let stallTimeout: TimeInterval = 60
        let progressTracker = ExportProgressTracker()
        progressTracker.recordProgress(0)

        // Progress monitoring
        let progressMonitor = Task {
            for await state in exportSession.states(updateInterval: 5) {
                if Task.isCancelled { return }
                switch state {
                case .pending:
                    progressHandler(0, .queued, nil, "Pending")
                case .waiting:
                    progressHandler(0, .queued, nil, "Waiting")
                case let .exporting(progress):
                    let progressValue = progress.fractionCompleted
                    progressTracker.recordProgress(progressValue)
                    progressHandler(0.3 + (progressValue * 0.7), .encoding, nil, "Encoding: \(Int(progressValue * 100))%")
                    if progressValue >= 0.999 { return }
                @unknown default:
                    break
                }
            }
        }
        defer { progressMonitor.cancel() }

        if cancellationCheck() { throw PreviewError.cancelled }

        // Cancellation + stall monitoring
        let stallDetected = CancellationToken()
        let cancellationMonitor = Task {
            while !Task.isCancelled {
                if cancellationCheck() {
                    logger.warning("Cancellation requested, cancelling export")
                    exportSession.cancelExport()
                    return
                }
                let elapsed = progressTracker.secondsSinceLastProgress
                if elapsed >= stallTimeout {
                    logger.error("Export stalled: no progress for \(Int(elapsed))s, cancelling")
                    stallDetected.cancel()
                    exportSession.cancelExport()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // check every 1s
            }
        }
        defer { cancellationMonitor.cancel() }

        // Perform the export
        do {
            try await exportSession.export(to: outputURL, as: config.format.avFileType)
        } catch {
            if stallDetected.isCancelled {
                try? FileManager.default.removeItem(at: outputURL)
                throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
            }
            if cancellationCheck() {
                try? FileManager.default.removeItem(at: outputURL)
                throw PreviewError.cancelled
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.encodingFailed("Export failed", error)
        }

        let finalStatus = exportSession.status
        let finalError = exportSession.error

        if stallDetected.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
        }

        if cancellationCheck() {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.cancelled
        }

        if let error = finalError {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.encodingFailed("Export failed", error)
        }

        guard finalStatus == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.encodingFailed(
                "Export finished with status: \(self.statusDescription(finalStatus))", nil
            )
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PreviewError.encodingFailed("Export completed but output file not found", nil)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        logger.info("Native export completed: \(outputURL.lastPathComponent) (\(String(format: "%.2f", Double(fileSize) / 1_048_576.0)) MB)")

        return outputURL
    }

}
