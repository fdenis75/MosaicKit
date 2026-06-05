import Foundation
import Testing
@testable import MosaicKit

/// Integration test that runs the `PreviewGeneratorCoordinator` batch pipeline
/// against a real folder of videos supplied by the tester.
///
/// ## Required environment variables
///
/// | Variable            | Description                                           |
/// |---------------------|-------------------------------------------------------|
/// | `PREVIEW_FOLDER`    | Absolute path to a directory containing video files   |
///
/// ## Optional environment variables
///
/// | Variable            | Description                                           |
/// |---------------------|-------------------------------------------------------|
/// | `FFMPEG_PATH`       | Absolute path to the `ffmpeg` binary (falls back to  |
/// |                     | Homebrew default locations when not set)              |
/// | `PREVIEW_RECURSIVE` | Set to `"1"` to scan subdirectories recursively      |
///
/// The test is automatically skipped when `PREVIEW_FOLDER` is not set or when
/// `MOSAICKIT_SUITE_MODE=none` (CI environment).
@Suite("PreviewCoordinator integration tests")
struct PreviewCoordinatorTests {

    // MARK: - Environment helpers

    private var folderURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["PREVIEW_FOLDER"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var ffmpegBinaryPath: String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FFMPEG_PATH"],
           fm.isExecutableFile(atPath: env) { return env }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private var isRecursive: Bool {
        ProcessInfo.processInfo.environment["PREVIEW_RECURSIVE"] == "1"
    }

    private var isCIMode: Bool {
        ProcessInfo.processInfo.environment["MOSAICKIT_SUITE_MODE"] == "none"
    }

    // MARK: - Tests

    @Test("Batch preview generation with hevc_videotoolbox FFmpeg pipeline")
    func batchPreviewGeneration() async throws {
        guard !isCIMode else {
            print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none")
            return
        }

        guard let folder = folderURL else {
            print("⏭️  Skipped: set PREVIEW_FOLDER to a directory containing video files")
            return
        }

        guard let ffmpegPath = ffmpegBinaryPath else {
            print("⏭️  Skipped: ffmpeg binary not found; set FFMPEG_PATH or install via Homebrew")
            return
        }

        // ── 1. Scan folder ────────────────────────────────────────────────────
        print("🔍 Scanning \(folder.path) (recursive: \(isRecursive))…")
        let videos = await scanVideos(in: folder, recursive: isRecursive)

        guard !videos.isEmpty else {
            print("⏭️  Skipped: no video files found in \(folder.path)")
            return
        }
        print("📹 Found \(videos.count) video(s)")
        for v in videos { print("    • \(v.title)") }

        // ── 2. Build output directory  {folder}/{yyyyMMdd_HHmmss} ────────────
        let timestamp: String = {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            return fmt.string(from: Date())
        }()
        let outputDirectory = folder.appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        print("📁 Output directory: \(outputDirectory.path)")

        // ── 3. Build PreviewConfiguration ────────────────────────────────────
        let encodingOptions = FFmpegEncodingOptions(
            videoCodec: .hevcVideoToolbox,
            crf: nil,
            speedPreset: .fast,
            maxResolution: ._1080p,
            audioCodec: .aac,
            audioBitrate: "128k"
        )

        let config = PreviewConfiguration(
            targetDuration: 60,
            density: .m,
            format: .mp4,
            includeAudio: true,
            outputDirectory: outputDirectory,
            compressionQuality: 0.8,
            exportMode: .ffmpeg,
            ffmpegBinaryPath: ffmpegPath,
            ffmpegTempFolder: nil,
            ffmpegEncodingOptions: encodingOptions,
            enableAppLifecycleMonitor: false
        )

        // ── 4. Run batch via coordinator ─────────────────────────────────────
        let coordinator = PreviewGeneratorCoordinator()
        let startTime = Date()

        let results = try await coordinator.generatePreviewsForBatch(
            videos: videos,
            config: config
        ) { progress in
            switch progress.status {
            case .queued:
                print("  ⏳ Queued:    \(progress.video.title)")
            case .analyzing, .extracting, .composing:
                print("  🔄 \(progress.status.displayLabel.padding(toLength: 22, withPad: " ", startingAt: 0)) \(progress.video.title)")
            case .encoding, .saving:
                let pct = Int(progress.progress * 100)
                let msg = progress.message.map { " — \($0)" } ?? ""
                print("  📊 \(progress.video.title): \(pct)%\(msg)")
            case .completed:
                let out = progress.outputURL?.lastPathComponent ?? ""
                let secs = String(format: "%.1f", Date().timeIntervalSince(startTime))
                print("  ✅ Completed: \(progress.video.title) → \(out) (\(secs)s)")
            case .failed:
                let err = progress.error?.localizedDescription ?? "unknown"
                print("  ❌ Failed:    \(progress.video.title) — \(err)")
            case .cancelled:
                print("  🚫 Cancelled: \(progress.video.title)")
            }
            fflush(stdout)
        }

        // ── 5. Report ─────────────────────────────────────────────────────────
        let elapsed = Date().timeIntervalSince(startTime)
        let succeeded = results.filter(\.isSuccess).count
        let failed    = results.filter { !$0.isSuccess }.count

        print("""

        ─────────────────────────────────────────────
        Batch complete in \(String(format: "%.1f", elapsed))s
          ✅ succeeded : \(succeeded)
          ❌ failed    : \(failed)
          📹 total     : \(results.count)
        ─────────────────────────────────────────────
        """)

        for result in results where !result.isSuccess {
            print("  ❌ \(result.video.title): \(result.error?.localizedDescription ?? "unknown error")")
        }

        #expect(succeeded > 0, "Expected at least one successful preview")
    }
}
