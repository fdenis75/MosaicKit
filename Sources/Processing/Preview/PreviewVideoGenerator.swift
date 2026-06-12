import Foundation
import AVFoundation
import OSLog
import Synchronization
import QuartzCore
import UniformTypeIdentifiers
import SJSAssetExportSession
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Thread-safe cancellation token
final class CancellationToken: Sendable {
    private let _cancelled = Mutex<Bool>(false)

    var isCancelled: Bool { _cancelled.withLock { $0 } }

    func cancel() { _cancelled.withLock { $0 = true } }
}

/// Thread-safe tracker for the last time export progress changed.
/// Used to detect stalled exports that stop making forward progress.
final class ExportProgressTracker: Sendable {
    private struct State { var time: Date = Date(); var value: Double = -1 }
    private let _state = Mutex<State>(State())

    /// Record that progress changed. Only updates the timestamp when the value actually moves.
    func recordProgress(_ value: Double) {
        _state.withLock { s in
            if value != s.value { s.value = value; s.time = Date() }
        }
    }

    /// Seconds since the last time progress actually changed.
    var secondsSinceLastProgress: TimeInterval {
        _state.withLock { Date().timeIntervalSince($0.time) }
    }
}

/// Actor responsible for generating preview videos from source videos
// @available(macOS 26, iOS 26, *)
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

        // Early-exit: if the resolved output already exists and `overwrite` is
        // false, short-circuit and return the existing URL.
        if !config.overwrite {
            let outputDir = config.generateOutputDirectory(for: video)
            let filename = config.generateFilename(for: video)
            let existingURL = outputDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: existingURL.path) {
                logger.info("Preview already exists, skipping generation: \(existingURL.path)")
                reportProgress(for: video, progress: 1.0, status: .completed, outputURL: existingURL)
                return existingURL
            }
        }

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

// MARK: - macOS background-focus monitor

/// Polls `NSWorkspace` every 500 ms and emits an OSLog warning (visible in Console.app)
/// plus a stdout line whenever another app steals focus from the export process.
///
/// This makes it straightforward to correlate a stall in the test output with a
/// "process went to background" event:
///
/// ```
/// [FOCUS ⬅️]  DJI_0080  backgrounded at 14:03:27.451  frontmost: Safari
/// ...
/// [FOCUS ▶️]  DJI_0080  foreground restored at 14:03:41.218  (14.8 s in background)
/// ```
///
/// Read the logs live with:
/// ```bash
/// log stream --predicate 'subsystem == "com.mosaickit"' --level debug
/// ```
#if os(macOS)
enum PreviewFocusMonitor {

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Starts the monitor and returns the background `Task` that drives it.
    /// Call `task.cancel()` (or let a `defer` do it) to stop monitoring.
    static func start(videoTitle: String, logger: Logger) -> Task<Void, Never> {
        Task { @MainActor in
            let ourPID    = ProcessInfo.processInfo.processIdentifier
            var lastPID   = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var bgStart   = Date?.none

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)

                let frontPID  = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard frontPID != lastPID else { continue }
                lastPID = frontPID

                let ts = timeFormatter.string(from: Date())

                if frontPID != ourPID {
                    // Went to background
                    bgStart = Date()
                    let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    let msg = "backgrounded at \(ts)  frontmost: \(appName)"
                    logger.warning("[FOCUS ⬅️] \(videoTitle, privacy: .public)  \(msg, privacy: .public)")
                    print("[FOCUS ⬅️]  \(videoTitle)  \(msg)")
                    fflush(stdout)
                } else {
                    // Returned to foreground
                    let elapsed = bgStart.map { String(format: "%.1f s in background", Date().timeIntervalSince($0)) } ?? ""
                    let msg = "foreground restored at \(ts)  \(elapsed)"
                    logger.info("[FOCUS ▶️] \(videoTitle, privacy: .public)  \(msg, privacy: .public)")
                    print("[FOCUS ▶️]  \(videoTitle)  \(msg)")
                    fflush(stdout)
                    bgStart = nil
                }
            }
        }
    }
}
#endif

// MARK: - Generation logic

/// Logic for preview generation, isolated to MainActor to ensure AVFoundation safety
// @available(macOS 26, iOS 26, *)
struct PreviewGenerationLogic {
    private static let logger = Logger(subsystem: "com.mosaickit", category: "PreviewGenerationLogic")

    private struct PreviewOverlayCue {
        let compositionStart: CMTime
        let displayDuration: CMTime
        let text: String
    }
    
    static func generate(
        for video: VideoInput,
        config: PreviewConfiguration,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        logger.info("Starting preview generation logic for \(video.title)")

        // On macOS, the system throttles or briefly suspends background processes,
        // which stalls AVAssetExportSession and AVVideoCompositionCoreAnimationTool
        // (both depend on VideoToolbox / Core Animation resources that are
        // deprioritised when another window has focus).
        // Holding a .userInitiated activity token tells the scheduler to keep
        // this process at full priority for the duration of the export.
        #if os(macOS)
        let exportActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "MosaicKit preview video generation"
        )
        defer { ProcessInfo.processInfo.endActivity(exportActivity) }

        // Background-focus monitor: logs to OSLog (Console.app) and stdout whenever
        // another app steals focus from the exporting process. Useful for correlating
        // export stalls with "went to background" events.
        let focusMonitor = PreviewFocusMonitor.start(videoTitle: video.title, logger: logger)
        defer { focusMonitor.cancel() }
        #endif

        #if os(iOS)
        // Request background execution time on iOS using key-value coding to remain 100% safe inside App Extensions
        let backgroundTaskID = Mutex<UIBackgroundTaskIdentifier>(.invalid)
        if let sharedApp = NSClassFromString("UIApplication")?.value(forKeyPath: "sharedApplication") as? UIApplication {
            let taskID = sharedApp.beginBackgroundTask(withName: "com.mosaickit.preview-export-\(video.id.uuidString)") {
                let id = backgroundTaskID.withLock { $0 }
                if id != .invalid {
                    sharedApp.endBackgroundTask(id)
                    backgroundTaskID.withLock { $0 = .invalid }
                }
            }
            backgroundTaskID.withLock { $0 = taskID }
        }
        defer {
            let id = backgroundTaskID.withLock { $0 }
            if id != .invalid,
               let sharedApp = NSClassFromString("UIApplication")?.value(forKeyPath: "sharedApplication") as? UIApplication {
                sharedApp.endBackgroundTask(id)
                backgroundTaskID.withLock { $0 = .invalid }
            }
        }
        #endif

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
        
        progressHandler(0.05, .analyzing, nil, "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: extractCount,
            extractDuration: extractDuration
        )

        if cancellationCheck() { throw PreviewError.cancelled }

        // FFmpeg preflight: validate binary before starting the expensive composition step
        if config.exportMode == .ffmpeg {
            guard let binaryPath = config.ffmpegBinaryPath else {
                throw PreviewError.invalidConfiguration("ffmpegBinaryPath must be set when exportMode is .ffmpeg")
            }
            try FFmpegEncoder.validate(binaryPath: binaryPath)
        }

        // Compose
        progressHandler(0.05, .composing, nil, "Composing \(timestamps.count) segments...")

        // Resolve custom target size based on export mode
        var customTargetSize: CGSize? = nil
        switch config.exportMode {
        case .native:
            customTargetSize = resolutionLimit(for: config.effectiveExportPreset)
        case .ffmpeg:
            if let res = config.ffmpegEncodingOptions?.maxResolution
                ?? FFmpegEncodingOptions.from(quality: config.compressionQuality, format: config.format).maxResolution {
                customTargetSize = res.cgSize
            }
        case .sjs:
            break
        }
        
        let videoComposition = try await composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            maxResolutionRaw: config.exportMaxResolutionRaw,
            customTargetSize: customTargetSize,
            includeOverlayCues: config.showTimestampOverlay,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() { throw PreviewError.cancelled }
        
        // Export — route based on configuration
        progressHandler(0.10, .encoding, nil, "Encoding preview video...")
        let returnURL: URL
        switch config.exportMode {
        case .native:
            returnURL = try await exportWithNativeSession(
                composition: videoComposition.composition,
                audioMix: videoComposition.audioMix,
                videoComposition: videoComposition.videoComposition,
                config: config,
                video: video,
                progressHandler: progressHandler,
                cancellationCheck: cancellationCheck
            )
        case .sjs:
            returnURL = try await exportWithSJSSession(
                composition: videoComposition.composition,
                audioMix: videoComposition.audioMix,
                videoComposition: videoComposition.videoComposition,
                config: config,
                video: video,
                progressHandler: progressHandler,
                cancellationCheck: cancellationCheck
            )
        case .ffmpeg:
            returnURL = try await exportWithFFmpeg(
                composition: videoComposition.composition,
                audioMix: videoComposition.audioMix,
                videoComposition: videoComposition.videoComposition,
                config: config,
                video: video,
                progressHandler: progressHandler,
                cancellationCheck: cancellationCheck
            )
        }

        return returnURL
    }
    
    /// Generate a preview composition without exporting (for video player playback)
    @MainActor
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
        
        progressHandler(0.05, .analyzing, nil, "Calculating timestamps...")
        let timestamps = try await calculateExtractTimestamps(
            asset: asset,
            video: video,
            extractCount: extractCount,
            extractDuration: extractDuration
        )

        if cancellationCheck() { throw PreviewError.cancelled }

        // Compose
        // AVVideoCompositionCoreAnimationTool (used for timestamp pills) is not supported
        // during live AVPlayerItem playback — omit overlay cues in this path.
        progressHandler(0.05, .composing, nil, "Composing \(timestamps.count) segments...")
        let compositionResult = try await
        composeVideoSegments(
            asset: asset,
            timestamps: timestamps,
            extractDuration: extractDuration,
            playbackSpeed: playbackSpeed,
            includeAudio: config.includeAudio,
            maxResolutionRaw: config.exportMaxResolutionRaw,
            includeOverlayCues: false,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )

        if cancellationCheck() { throw PreviewError.cancelled }

        // Create player item from composition
        progressHandler(0.20, .composing, nil, "Creating player item...")

        let playerItem = AVPlayerItem(asset: compositionResult.composition)
        
        // Apply video composition for scaling
        if let vc = compositionResult.videoComposition {
            playerItem.videoComposition = vc
        }
        
        // Apply audio mix if available
        if let mix = compositionResult.audioMix {
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
    
    /// - Parameter maxResolutionRaw: Raw `String` value of an `ExportMaxResolution` case, or `nil`.
    ///   Passed as a plain `String` so this function is callable on macOS 15+.
    ///   The actual downscaling (`AVVideoComposition.Configuration` & friends) is gated
    ///   behind `#available(macOS 26, iOS 26, *)` inside the function body.
    private static func composeVideoSegments(
        asset: AVAsset,
        timestamps: [(start: CMTime, duration: CMTime)],
        extractDuration: TimeInterval,
        playbackSpeed: Double,
        includeAudio: Bool,
        maxResolutionRaw: String?,
        customTargetSize: CGSize? = nil,
        includeOverlayCues: Bool = false,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix?, videoComposition: AVVideoComposition?) {
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
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
        
        var compositionAudioTrack: AVMutableCompositionTrack?
        if audioTrack != nil {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        
        // Insert segments
        var insertTime = CMTime.zero
        let progressStep = 0.05 / Double(timestamps.count)
        var skippedSegments = 0
        var overlayCues: [PreviewOverlayCue] = []
        
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
                let compositionStart = insertTime

                // Insert video segment
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)
                // Insert audio segment from pre-loaded track
                if let srcAudio = audioTrack, let dstAudio = compositionAudioTrack {
                    try dstAudio.insertTimeRange(timeRange, of: srcAudio, at: insertTime)
                }

                // Apply time scaling on the COMPOSITION (scales all tracks atomically)
                let segmentOutputDuration: CMTime
                if playbackSpeed != 1.0 {
                    let scaledDuration = CMTime(
                        seconds: extractDuration / playbackSpeed,
                        preferredTimescale: 600
                    )
                    let scaleRange = CMTimeRange(start: insertTime, duration: timestamp.duration)
                    composition.scaleTimeRange(scaleRange, toDuration: scaledDuration)
                    segmentOutputDuration = scaledDuration
                    insertTime = CMTimeAdd(insertTime, scaledDuration)
                } else {
                    segmentOutputDuration = timestamp.duration
                    insertTime = CMTimeAdd(insertTime, timestamp.duration)
                }

                overlayCues.append(
                    PreviewOverlayCue(
                        compositionStart: compositionStart,
                        displayDuration: CMTime(
                            seconds: min(1.0, CMTimeGetSeconds(segmentOutputDuration)),
                            preferredTimescale: 600
                        ),
                        text: formatExtractTimestamp(seconds: CMTimeGetSeconds(timestamp.start))
                    )
                )
                
                let progress = 0.05 + (progressStep * Double(index + 1))
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
        
        // Create audio mix if we have audio and time-scaling is in play.
        // .timeDomain is used instead of .spectral: both support offline export, but .spectral's
        // FFT-based pitch correction is CPU-intensive enough to stall the remakerOfflineMixer
        // thread when the process is backgrounded. .timeDomain uses less CPU at the cost of
        // minor artifacts above ~1.5×, which is acceptable for preview generation.
        // .varispeed is playback-only and causes AudioQueue rate-change conflicts during export.
        var audioMix: AVMutableAudioMix?
        if let compAudioTrack = compositionAudioTrack, playbackSpeed != 1.0 {
            let params = AVMutableAudioMixInputParameters(track: compAudioTrack)
            params.trackID = compAudioTrack.trackID
            params.audioTimePitchAlgorithm = .timeDomain
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }
        
        let videoComp = try await buildVideoComposition(
            composition: composition,
            sourceVideoTrack: videoTrack,
            compositionVideoTrack: compositionVideoTrack,
            overlayCues: includeOverlayCues ? overlayCues : [],
            maxResolutionRaw: maxResolutionRaw,
            customTargetSize: customTargetSize
        )
        
        return (composition, audioMix, videoComp)
    }

    private static func buildVideoComposition(
        composition: AVMutableComposition,
        sourceVideoTrack: AVAssetTrack,
        compositionVideoTrack: AVMutableCompositionTrack,
        overlayCues: [PreviewOverlayCue],
        maxResolutionRaw: String?,
        customTargetSize: CGSize? = nil
    ) async throws -> AVVideoComposition {
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
        let transformedSize = naturalSize.applying(preferredTransform)
        let sourceWidth = abs(transformedSize.width)
        let sourceHeight = abs(transformedSize.height)

        var renderSize = CGSize(width: sourceWidth, height: sourceHeight)
        var finalTransform = preferredTransform

        // Resolve target constraints
        var targetMaxWidth = sourceWidth
        var targetMaxHeight = sourceHeight
        var needsScaling = false

        if let customSize = customTargetSize {
            // The export preset already defines its own output resolution (e.g. an
            // AVAssetExportSession preset like "HEVC1920x1080"). That resolution is
            // authoritative: it's the resize "forced by the preset", and the exporter
            // will apply it regardless. Intersecting it with `exportMaxResolution` here
            // would either be a no-op (when the two agree) or fight the preset (when
            // they don't) — in both cases producing a redundant second resize pass.
            targetMaxWidth = customSize.width
            targetMaxHeight = customSize.height
            needsScaling = true
        } else if #available(macOS 26, iOS 26, *),
                  let rawRes = maxResolutionRaw,
                  let maxRes = ExportMaxResolution(rawValue: rawRes) {
            // No preset-forced resolution (e.g. "same as source" presets) — fall back
            // to the configured `exportMaxResolution` cap.
            targetMaxWidth = CGFloat(maxRes.maxWidth)
            targetMaxHeight = CGFloat(maxRes.maxHeight)
            needsScaling = true
        }

        if needsScaling && (sourceWidth > targetMaxWidth || sourceHeight > targetMaxHeight) {
            let scaleX = targetMaxWidth / sourceWidth
            let scaleY = targetMaxHeight / sourceHeight
            let scale = min(scaleX, scaleY)
            renderSize = CGSize(
                width: (sourceWidth * scale).rounded(.down),
                height: (sourceHeight * scale).rounded(.down)
            )
            finalTransform = preferredTransform.concatenating(
                CGAffineTransform(scaleX: scale, y: scale)
            )

            logger.info("Scaling composition from \(Int(sourceWidth))x\(Int(sourceHeight)) to \(Int(renderSize.width))x\(Int(renderSize.height))")
        }

        // Intentionally always uses the legacy (deprecated) construction path:
        // AVVideoComposition.Configuration(for:prototypeInstruction:) auto-derives
        // per-segment layer instructions from the composition's own track geometry,
        // discarding the scale transform set on the prototype instruction. That
        // resizes the render canvas without scaling the rendered frame content.
        // AVMutableVideoCompositionLayerInstruction.setTransform is the only path
        // that actually honours `finalTransform`.
        return buildLegacyVideoComposition(
            composition: composition,
            compositionVideoTrack: compositionVideoTrack,
            overlayCues: overlayCues,
            finalTransform: finalTransform,
            renderSize: renderSize,
            nominalFrameRate: nominalFrameRate
        )
    }

    private static func buildLegacyVideoComposition(
        composition: AVMutableComposition,
        compositionVideoTrack: AVMutableCompositionTrack,
        overlayCues: [PreviewOverlayCue],
        finalTransform: CGAffineTransform,
        renderSize: CGSize,
        nominalFrameRate: Float
    ) -> AVVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(nominalFrameRate > 0 ? nominalFrameRate : 30)
        )

        if !overlayCues.isEmpty {
            videoComposition.animationTool = makeOverlayAnimationTool(
                renderSize: renderSize,
                cues: overlayCues
            )
        }

        return videoComposition
    }

    private static func makeOverlayAnimationTool(
        renderSize: CGSize,
        cues: [PreviewOverlayCue]
    ) -> AVVideoCompositionCoreAnimationTool {
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let overlayLayer = CALayer()
        overlayLayer.frame = parentLayer.frame
        parentLayer.addSublayer(overlayLayer)

        for cue in cues {
            overlayLayer.addSublayer(
                makeTimestampPillLayer(
                    text: cue.text,
                    renderSize: renderSize,
                    startTime: CMTimeGetSeconds(cue.compositionStart),
                    duration: CMTimeGetSeconds(cue.displayDuration)
                )
            )
        }

        let tool: AVVideoCompositionCoreAnimationTool
        if #available(macOS 26, iOS 26, *) {
            let configuration = AVVideoCompositionCoreAnimationTool.Configuration(
                postProcessingAsVideoLayer: videoLayer,
                containingLayer: parentLayer
            )
            tool = AVVideoCompositionCoreAnimationTool(configuration: configuration)
        } else {
            tool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        CATransaction.commit()
        return tool
    }

    private static func makeTimestampPillLayer(
        text: String,
        renderSize: CGSize,
        startTime: TimeInterval,
        duration: TimeInterval
    ) -> CALayer {
        let fontSize = max(18, min(renderSize.width * 0.028, 32))
        let horizontalPadding = fontSize * 0.65
        let verticalPadding = fontSize * 0.34
        let margin = max(18, min(renderSize.width * 0.03, 32))

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: previewTimestampFont(size: fontSize),
                .foregroundColor: previewTimestampTextColor()
            ]
        )
        let textBounds = attributedText.boundingRect(
            with: CGSize(width: renderSize.width, height: renderSize.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral

        let pillWidth = ceil(textBounds.width + (horizontalPadding * 2))
        let pillHeight = ceil(textBounds.height + (verticalPadding * 2))

        let pillLayer = CALayer()
        pillLayer.frame = CGRect(
            x: margin,
            y: margin,
            width: pillWidth,
            height: pillHeight
        )
        pillLayer.backgroundColor = previewTimestampBackgroundColor().cgColor
        pillLayer.cornerRadius = pillHeight / 2
        pillLayer.opacity = 0

        // CATextLayer does not render reliably in AVVideoCompositionCoreAnimationTool's
        // offline export context. Render the text into a CGImage via CoreText instead
        // and use a plain CALayer whose .contents is the image.
        let textLayer = CALayer()
        textLayer.frame = CGRect(
            x: horizontalPadding,
            y: (pillHeight - textBounds.height) / 2,
            width: textBounds.width,
            height: textBounds.height
        )
        textLayer.contents = renderTextToCGImage(
            text: text,
            fontSize: fontSize,
            size: CGSize(width: textBounds.width, height: textBounds.height)
        )
        textLayer.contentsGravity = .resize
        pillLayer.addSublayer(textLayer)

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.001, 0.999, 1]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + startTime
        animation.duration = max(0.01, duration)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        pillLayer.add(animation, forKey: "extractTimestampVisibility")

        return pillLayer
    }

    /// Render `text` into a CGImage using CoreText.
    ///
    /// CoreText draws in a bottom-left-origin CGContext, which is the same coordinate
    /// system used by AVVideoCompositionCoreAnimationTool during offline export on both
    /// macOS and iOS. This avoids the rendering problems that `CATextLayer` exhibits
    /// in that context (text invisible or misplaced).
    private static func renderTextToCGImage(
        text: String,
        fontSize: CGFloat,
        size: CGSize
    ) -> CGImage? {
        let width  = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        guard width > 0, height > 0 else { return nil }

        // Build a CoreText line with CGColor so the foreground colour survives
        // the CGContext rendering path (NSColor/UIColor are not safe here).
        #if canImport(AppKit)
        let ctFont = previewTimestampFont(size: fontSize) as CTFont
        #elseif canImport(UIKit)
        let ctFont = previewTimestampFont(size: fontSize) as CTFont
        #endif
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        let cfString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(cfString)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Centre the glyphs vertically within the image using CoreText metrics.
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let baselineY = (CGFloat(height) - bounds.height) / 2 - bounds.origin.y
        ctx.textPosition = CGPoint(x: 0, y: baselineY)
        CTLineDraw(line, ctx)

        return ctx.makeImage()
    }

    static func formatExtractTimestamp(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    #if canImport(AppKit)
    private static func previewTimestampFont(size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    private static func previewTimestampTextColor() -> NSColor {
        .white
    }

    private static func previewTimestampBackgroundColor() -> NSColor {
        NSColor(calibratedWhite: 0.08, alpha: 0.84)
    }
    #elseif canImport(UIKit)
    private static func previewTimestampFont(size: CGFloat) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    private static func previewTimestampTextColor() -> UIColor {
        .white
    }

    private static func previewTimestampBackgroundColor() -> UIColor {
        UIColor(white: 0.08, alpha: 0.84)
    }
    #endif
    
    /// Export using the FFmpeg pipeline: passthrough export to temp file, then FFmpeg transcode.
    @MainActor
    private static func exportWithFFmpeg(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        videoComposition: AVVideoComposition?,
        config: PreviewConfiguration,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        logger.info("Starting FFmpeg pipeline for \(video.title)")
        return try await FFmpegEncoder.encode(
            composition: composition,
            audioMix: audioMix,
            videoComposition: videoComposition,
            config: config,
            video: video,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
    }

    /// Export using SJSAssetExportSession (custom exporter with fine-grained codec/bitrate control)
    private static func exportWithSJSSession(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        videoComposition: AVVideoComposition?,
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
        // Resolution capping for the SJS render size.
        // `ExportMaxResolution.maxWidth/maxHeight` require macOS 26+ / iOS 26+.
        // On earlier OS versions renderSize stays at naturalSize (full source resolution).
        var renderSize: CGSize = naturalSize
        if #available(macOS 26, iOS 26, *),
           let maxRes = config.exportMaxResolution,
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
                width: originalWidth,
                height: originalHeight,
                renderSize: renderSize
            )
            
            logger.info("SJS export: format=\(config.format.rawValue), q.uality=, audioBitrate=\(audioBitrate)")

            // Stall detection: cancel if no progress for the timeout period.
            // macOS doubles the budget because a backgrounded process can legitimately
            // pause for >60 s before the ProcessInfo activity assertion resumes it.
            #if os(macOS)
            let stallTimeout: TimeInterval = 120
            #else
            let stallTimeout: TimeInterval = 60
            #endif
            let progressTracker = ExportProgressTracker()
            progressTracker.recordProgress(0)
            let stallDetected = CancellationToken()
            
            // Start progress monitoring task
            let progressTask = Task {
                for await progress in exporter.progressStream {
                    if cancellationCheck() { break }
                    let progressValue = Double(progress)
                    progressTracker.recordProgress(progressValue)
                    let exportProgress = 0.10 + (progressValue * 0.90)
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
            
            // Perform the export — detached at userInitiated priority so the export is
            // not deprioritized when the calling process goes to the background.
            do {
                // Safe: composition is created and fully configured on this actor before the cast;
                // SJSAssetExportSession only reads the asset during the export call below.
                nonisolated(unsafe) let compositionAsset = composition as AVAsset

                if let vc = videoComposition {
                    // Use the raw-settings overload so we can pass our custom video composition for scaling.
                    try await Task.detached(priority: .userInitiated) {
                        try await exporter.export(
                            asset: compositionAsset,
                            audioOutputSettings: AudioOutputSettings.default.settingsDictionary,
                            videoOutputSettings: videoConfig.settingsDictionary,
                            composition: vc,
                            to: outputURL,
                            as: config.format.avFileType
                        )
                    }.value
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try await exporter.export(
                            asset: compositionAsset,
                            audio: .default,
                            video: videoConfig,
                            to: outputURL,
                            as: config.format.avFileType
                        )
                    }.value
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
        static func prepareOutputURL(config: PreviewConfiguration, video: VideoInput) throws -> URL {
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
        
        /// Determine video and audio settings based on quality level and original dimensions.
        ///
        /// Resolution capping is handled by the caller via `renderSize`; this function
        /// does not reference `ExportMaxResolution` directly and is available on all OS versions.
        private static func videoSettings(
            for quality: Double,
            format: VideoFormat,
            presetname: SjSExportPreset?,
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
    
    private static func resolutionLimit(for presetName: String) -> CGSize? {
        nativeExportPreset.maxResolution(forPresetName: presetName)
    }
    

    
    /// Export using AVAssetExportSession (Apple's native preset-based exporter)
    /// @MainActor ensures exportSession and its Task closures share the same isolation,
    /// avoiding 'sending' parameter errors for the non-Sendable AVAssetExportSession.
    @MainActor
    private static func exportWithNativeSession(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        videoComposition: AVVideoComposition?,
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

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: preset
        ) else {
            throw PreviewError.encodingFailed("Failed to create export session with preset '\(preset)'", nil)
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = config.format.avFileType
        
#if os(macOS)
        exportSession.allowsParallelizedExport = true
        #endif
        exportSession.shouldOptimizeForNetworkUse = true

        // Apply video composition for resolution scaling
        if let vc = videoComposition {
            exportSession.videoComposition = vc
        }
        if let mix = audioMix {
            exportSession.audioMix = mix
        }

        // Stall detection: cancel if no progress for the timeout period.
        // macOS doubles the budget because a backgrounded process can legitimately
        // pause for >60 s before the ProcessInfo activity assertion resumes it.
        #if os(macOS)
        let stallTimeout: TimeInterval = 120
        #else
        let stallTimeout: TimeInterval = 60
        #endif
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
                    progressHandler(0.10 + (progressValue * 0.90), .encoding, nil, "Encoding: \(Int(progressValue * 100))%")
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

        // Perform the export — detached at userInitiated priority so the export is
        // not deprioritized when the calling process goes to the background.
        do {
            nonisolated(unsafe) let sessionRef = exportSession
            try await Task.detached(priority: .userInitiated) {
                try await sessionRef.export(to: outputURL, as: config.format.avFileType)
            }.value
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

        if stallDetected.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
        }

        if cancellationCheck() {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.cancelled
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PreviewError.encodingFailed("Export completed but output file not found", nil)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        logger.info("Native export completed: \(outputURL.lastPathComponent) (\(String(format: "%.2f", Double(fileSize) / 1_048_576.0)) MB)")

        return outputURL
    }

}
