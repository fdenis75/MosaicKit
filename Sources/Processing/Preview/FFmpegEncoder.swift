import Foundation
import AVFoundation
import OSLog

/// Handles the FFmpeg encoding stage of the passthrough pipeline.
///
/// Flow:
///  1. Validate the ffmpeg binary.
///  2. Export the `AVMutableComposition` to a temp `.mov` file using the
///     `AVAssetExportPresetPassthrough` preset (no re-encode, fastest possible).
///  3. Run the ffmpeg process to transcode the temp file to the final destination.
///  4. Clean up the temp file regardless of outcome.
///
/// `Process` is macOS-only; on iOS/macCatalyst all entry points throw
/// `PreviewError.invalidConfiguration`.
enum FFmpegEncoder {

    private static let logger = Logger(subsystem: "com.mosaicKit", category: "FFmpegEncoder")

    // MARK: - Validation

    /// Verify that `path` points to an executable file.
    /// Call before starting the composition to fail fast.
    static func validate(binaryPath: String) throws {
        #if os(macOS)
        let fm = FileManager.default
        // Resolve symlinks so /opt/homebrew/bin/ffmpeg → real Cellar path before checking.
        let resolvedPath = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        guard fm.fileExists(atPath: resolvedPath) else {
            throw PreviewError.ffmpegNotFound(path: binaryPath)
        }
        guard fm.isExecutableFile(atPath: resolvedPath) else {
            throw PreviewError.ffmpegNotFound(path: binaryPath)
        }
        #else
        throw PreviewError.invalidConfiguration("FFmpeg export is only supported on macOS")
        #endif
    }

    // MARK: - Disk space preflight

    /// Rough check: available space on the temp volume must be at least `minimumMB` MB.
    static func checkTempDiskSpace(at url: URL, minimumMB: Int = 500) throws {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return  // can't determine; proceed optimistically
        }
        let requiredBytes = Int64(minimumMB) * 1_048_576
        guard available >= requiredBytes else {
            throw PreviewError.invalidConfiguration(
                "Insufficient disk space in temp folder: \(available / 1_048_576) MB available, \(minimumMB) MB required"
            )
        }
    }

    // MARK: - Main encode entry point

    /// Export `composition` via passthrough to a temp file, then transcode to `outputURL` using ffmpeg.
    ///
    /// - Parameters:
    ///   - composition: The fully assembled `AVMutableComposition`.
    ///   - audioMix: Optional audio mix.
    ///   - videoComposition: Optional video composition (scaling / overlays). Not applied during
    ///     passthrough — the composition's built-in scaling handles resolution at composition time.
    ///   - config: Preview configuration (provides binary path, temp folder, encoding options, format).
    ///   - video: Source video metadata used for progress reporting.
    ///   - progressHandler: Called with (fraction 0–1, status, outputURL?, message?).
    ///   - cancellationCheck: Returns `true` if the operation has been cancelled.
    /// - Returns: The final output `URL`.
    @MainActor
    static func encode(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        videoComposition: AVVideoComposition?,
        config: PreviewConfiguration,
        video: VideoInput,
        progressHandler: @escaping @Sendable (Double, PreviewGenerationStatus, URL?, String?) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        #if os(macOS)
        guard let binaryPath = config.ffmpegBinaryPath else {
            throw PreviewError.invalidConfiguration("ffmpegBinaryPath is required when exportMode is .ffmpeg")
        }

        // Resolve / create temp directory
        let tempDir = try resolveTempDirectory(from: config.ffmpegTempFolder)
        let tempURL = tempDir.appendingPathComponent("\(UUID().uuidString)_passthrough.mov")

        // Disk space preflight on the temp volume
        try checkTempDiskSpace(at: tempDir)

        // Determine final output URL
        let outputURL = try PreviewGenerationLogic.prepareOutputURL(config: config, video: video)

        logger.info("FFmpeg pipeline: passthrough → \(tempURL.lastPathComponent), encode → \(outputURL.lastPathComponent)")

        // Ensure temp artefacts are always cleaned up
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            // Only remove auto-created temp dirs (those under MosaicKitFFmpeg), not user-specified ones
            if config.ffmpegTempFolder == nil {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // MARK: Phase 1 – Passthrough export to temp file

        progressHandler(0.10, .encoding, nil, "Passthrough export…")

        try await exportPassthrough(
            composition: composition,
            audioMix: audioMix,
            outputURL: tempURL,
            progressHandler: { fraction, message in
                // Map passthrough progress to 0.10 → 0.30
                progressHandler(0.10 + fraction * 0.20, .encoding, nil, message)
            },
            cancellationCheck: cancellationCheck
        )

        if cancellationCheck() {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewError.cancelled
        }

        // MARK: Phase 2 – FFmpeg transcode

        progressHandler(0.30, .encoding, nil, "FFmpeg encoding…")

        let options = config.ffmpegEncodingOptions
            ?? FFmpegEncodingOptions.from(quality: config.compressionQuality, format: config.format)

        let args = options.buildArguments(
            inputURL: tempURL,
            outputURL: outputURL,
            includeAudio: config.includeAudio
        )

        // Remove any partial output from a previous failed attempt
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            try await runFFmpeg(
                binaryPath: binaryPath,
                arguments: args,
                totalDuration: composition.duration.seconds,
                progressHandler: { fraction, message in
                    // Map ffmpeg progress to 0.30 → 1.00
                    progressHandler(0.30 + fraction * 0.70, .encoding, nil, message)
                },
                cancellationCheck: cancellationCheck
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PreviewError.encodingFailed("FFmpeg produced no output file", nil)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        logger.info("FFmpeg encode completed: \(outputURL.lastPathComponent) (\(String(format: "%.2f", Double(fileSize) / 1_048_576.0)) MB)")

        progressHandler(1.0, .completed, outputURL, "Encoding complete")
        return outputURL

        #else
        throw PreviewError.invalidConfiguration("FFmpeg export is only supported on macOS")
        #endif
    }

    // MARK: - Passthrough export

    #if os(macOS)
    @MainActor
    private static func exportPassthrough(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        outputURL: URL,
        progressHandler: @escaping @Sendable (Double, String) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw PreviewError.encodingFailed("Failed to create passthrough export session", nil)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.allowsParallelizedExport = true

        if let mix = audioMix { exportSession.audioMix = mix }
        // videoComposition is intentionally NOT set: applying it would force re-encoding,
        // defeating the purpose of a passthrough export.

        let stallTimeout: TimeInterval = 120
        let progressTracker = ExportProgressTracker()
        progressTracker.recordProgress(0)
        let stallDetected = CancellationToken()

        let progressMonitor = Task {
            for await state in exportSession.states(updateInterval: 3) {
                if Task.isCancelled { return }
                switch state {
                case let .exporting(p):
                    let v = p.fractionCompleted
                    progressTracker.recordProgress(v)
                    progressHandler(v, "Passthrough: \(Int(v * 100))%")
                    if v >= 0.999 { return }
                default: break
                }
            }
        }
        defer { progressMonitor.cancel() }

        let stallMonitor = Task {
            while !Task.isCancelled {
                if cancellationCheck() { exportSession.cancelExport(); return }
                let elapsed = progressTracker.secondsSinceLastProgress
                if elapsed >= stallTimeout {
                    logger.error("Passthrough export stalled (\(Int(elapsed))s), cancelling")
                    stallDetected.cancel()
                    exportSession.cancelExport()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { stallMonitor.cancel() }

        do {
            nonisolated(unsafe) let sessionRef = exportSession
            try await Task.detached(priority: .userInitiated) {
                try await sessionRef.export(to: outputURL, as: .mov)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if stallDetected.isCancelled {
                throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
            }
            if cancellationCheck() { throw PreviewError.cancelled }
            throw PreviewError.encodingFailed("Passthrough export failed", error)
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
            throw PreviewError.encodingFailed("Passthrough export produced no output file", nil)
        }
        progressHandler(1.0, "Passthrough complete")
        logger.debug("Passthrough export finished: \(outputURL.lastPathComponent)")
    }

    // MARK: - FFmpeg process

    private static func runFFmpeg(
        binaryPath: String,
        arguments: [String],
        totalDuration: Double,
        progressHandler: @escaping @Sendable (Double, String) -> Void,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) async throws {
        logger.debug("Running ffmpeg: \(([binaryPath] + arguments).joined(separator: " "))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        // Pipe stderr for progress parsing; discard stdout
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let ffmpegTimeout: TimeInterval = 3600  // 1-hour hard ceiling
        let startTime = Date()
        let progressTracker = ExportProgressTracker()
        progressTracker.recordProgress(0)
        let stallDetected = CancellationToken()
        let processFinished = CancellationToken()

        // Reference types so they can be safely captured across concurrency boundaries
        // without triggering Swift 6 Sendable errors (Process and Pipe are not Sendable).
        nonisolated(unsafe) let processRef = process
        nonisolated(unsafe) let pipeRef = stderrPipe

        // Mutable stderr state: only accessed from Foundation's serial readability queue.
        // Wrapped in a class so the @escaping closure can mutate it without a Swift 6
        // "capture of mutable variable" error.
        final class StderrState: @unchecked Sendable { var buffer: String = "" }
        let stderrState = StderrState()

        // readabilityHandler fires on Foundation's internal serial queue whenever
        // new data arrives from the ffmpeg process's stderr.
        pipeRef.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8),
                  !chunk.isEmpty else { return }
            stderrState.buffer += chunk

            guard totalDuration > 0 else { return }

            // Parse every "time=HH:MM:SS.ss" token; keep only the last value.
            // Operate on a snapshot to avoid index-invalidation if the buffer is trimmed below.
            let snapshot = stderrState.buffer
            var latestElapsed: Double?
            let pattern = #/time=(\d{2}):(\d{2}):(\d{2})\.(\d{2})/#
            var searchStart = snapshot.startIndex
            while searchStart < snapshot.endIndex,
                  let match = snapshot[searchStart...].firstMatch(of: pattern) {
                let h = Double(match.1) ?? 0
                let m = Double(match.2) ?? 0
                let s = Double(match.3) ?? 0
                let cs = Double(match.4) ?? 0
                latestElapsed = h * 3600 + m * 60 + s + cs / 100
                searchStart = match.range.upperBound
            }
            if let elapsed = latestElapsed {
                let fraction = min(elapsed / totalDuration, 1.0)
                progressTracker.recordProgress(fraction)
                progressHandler(fraction, "FFmpeg: \(Int(fraction * 100))%")
            }

            // Trim buffer to avoid unbounded growth (keep last 8 KB)
            if stderrState.buffer.utf8.count > 8192 {
                let drop = stderrState.buffer.utf8.count - 4096
                stderrState.buffer = String(stderrState.buffer.dropFirst(drop))
            }
        }

        // Watchdog: terminates the process on user cancellation or stall
        let watchdog = Task {
            while !Task.isCancelled && !processFinished.isCancelled {
                if cancellationCheck() {
                    logger.warning("Cancellation requested, terminating ffmpeg")
                    processRef.terminate()
                    return
                }
                let elapsed = progressTracker.secondsSinceLastProgress
                let total = Date().timeIntervalSince(startTime)
                if elapsed >= 120 || total >= ffmpegTimeout {
                    logger.error("FFmpeg stalled or timed out (\(Int(elapsed))s since last progress), terminating")
                    stallDetected.cancel()
                    processRef.terminate()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        defer {
            watchdog.cancel()
            pipeRef.fileHandleForReading.readabilityHandler = nil
        }

        try processRef.run()

        // Wait for process exit on a DispatchQueue thread to avoid blocking the Swift
        // concurrency pool (waitUntilExit() is a blocking call).
        let exitCode = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .utility).async {
                processRef.waitUntilExit()
                processFinished.cancel()
                continuation.resume(returning: processRef.terminationStatus)
            }
        }

        if exitCode != 0 {
            if stallDetected.isCancelled {
                throw PreviewError.exportStalled(elapsedSeconds: Int(progressTracker.secondsSinceLastProgress))
            }
            if cancellationCheck() { throw PreviewError.cancelled }
            throw PreviewError.ffmpegEncodingFailed(exitCode: exitCode, output: "FFmpeg exited with code \(exitCode)")
        }

        if cancellationCheck() { throw PreviewError.cancelled }
        logger.info("FFmpeg process completed successfully (exit 0)")
    }

    // MARK: - Helpers

    private static func resolveTempDirectory(from configured: URL?) throws -> URL {
        if let dir = configured {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitFFmpeg", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    #endif
}
