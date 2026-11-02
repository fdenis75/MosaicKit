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
/// | `MOSAICKIT_LOCALFOLDER` | Absolute path to a directory containing video files |
///
/// ## Optional environment variables
///
/// | Variable            | Description                                           |
/// |---------------------|-------------------------------------------------------|
/// | `MOSAICKIT_FFMPEG_PATH` | Absolute path to the `ffmpeg` binary (falls back to  |
/// |                     | Homebrew default locations when not set)              |
/// | `MOSAICKIT_PREVIEW_RECURSIVE` | Set to `"1"` to scan subdirectories recursively      |
///
/// The test is automatically skipped when `MOSAICKIT_LOCALFOLDER` is not set or when
/// `MOSAICKIT_SUITE_MODE=none` (CI environment).
@Suite("PreviewCoordinator integration tests")
struct PreviewCoordinatorTests {

    // MARK: - Environment helpers

    private var folderURL: URL? { TestEnvironment.localFolder }
    private static let runTimestamp: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }()

  //  private static let runOutputDirectory: URL =
//        folderURL.appendingPathComponent(runTimestamp)
    
    private var ffmpegBinaryPath: String? { TestEnvironment.ffmpegPath }

    private var isRecursive: Bool {
        TestEnvironment.flag("MOSAICKIT_PREVIEW_RECURSIVE")
    }

    private var isCIMode: Bool {
        TestEnvironment.isCIMode
    }

    // MARK: - Tests

    @Test("Batch preview generation timing across concurrency settings 1/2/4/8")
    func batchPreviewGeneration() async throws {
    /*    guard !isCIMode else {
            print("⏭️  Skipped: MOSAICKIT_SUITE_MODE=none")
            return
        }*/

        guard let folder = folderURL else {
            print("⏭️  Skipped: set MOSAICKIT_LOCALFOLDER to a directory containing video files")
            return
        }

        guard let ffmpegPath = ffmpegBinaryPath else {
            print("⏭️  Skipped: ffmpeg binary not found; set MOSAICKIT_FFMPEG_PATH or install via Homebrew")
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

        // ── 2. Shared root output directory  {output folder}/PreviewCoordinator/{yyyyMMdd_HHmmss} ───────
        let timestamp: String = {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            return fmt.string(from: Date())
        }()
        let rootOutputDirectory = try TestEnvironment.outputFolder(named: "PreviewCoordinator")
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: rootOutputDirectory, withIntermediateDirectories: true)
        print("📁 Root output directory: \(rootOutputDirectory.path)")

        // ── 3. Run the batch with several concurrency settings ───────────────
        let concurrencySettings = [8, 16]
        var timings: [(concurrency: Int, elapsed: TimeInterval, succeeded: Int, failed: Int)] = []

        for concurrency in concurrencySettings {
            let runOutputDirectory = rootOutputDirectory
                .appendingPathComponent("concurrency_\(concurrency)", isDirectory: true)
            try FileManager.default.createDirectory(at: runOutputDirectory, withIntermediateDirectories: true)

            let encodingOptions = FFmpegEncodingOptions(
                videoCodec: .hevcVideoToolbox,
                crf: nil,
                speedPreset: .ultrafast,
                maxResolution: ._720p,
                audioCodec: .aac,
                audioBitrate: "64k"
            )

            let config = PreviewConfiguration(
                targetDuration: 30,
                density: .m,
                format: .mp4,
                includeAudio: true,
                outputDirectory: runOutputDirectory,
                compressionQuality: 0.8,
                exportMode: .ffmpeg,
                ffmpegBinaryPath: ffmpegPath,
                ffmpegTempFolder: nil,
                ffmpegEncodingOptions: encodingOptions,
                enableAppLifecycleMonitor: false,
                enableExportRetry: false
            )

            print("""

            ═════════════════════════════════════════════
            ▶️  Run with concurrencyLimit = \(concurrency)
            ═════════════════════════════════════════════
            """)

            let coordinator = PreviewGeneratorCoordinator(concurrencyLimit: concurrency)
            let startTime = Date()
            let progressTracker = ProgressBucketTracker()

            let results = try await coordinator.generatePreviewsForBatch(
                videos: videos,
                config: config
            ) { progress in
                switch progress.status {
               case .queued:
                    print("  ⏳ Queued:    \(progress.video.title)")
                case .analyzing, .extracting, .composing:
                    return
                 //   print("  🔄 \(progress.status.displayLabel.padding(toLength: 22, withPad: " ", startingAt: 0)) \(progress.video.title)")
                case .encoding, .saving:
                    return
                 /*   let pct = Int(progress.progress * 100)
                    let bucket = min(4, max(0, pct / 25))
                    guard progressTracker.shouldReport(key: progress.video.title, bucket: bucket) else { break }
                    let msg = progress.message.map { " — \($0)" } ?? ""
                    print("  📊 \(progress.video.title): \(bucket * 25)%\(msg)")*/
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

            let elapsed = Date().timeIntervalSince(startTime)
            let succeeded = results.filter(\.isSuccess).count
            let failed    = results.filter { !$0.isSuccess }.count

            print("""

            ─────────────────────────────────────────────
            Concurrency \(concurrency): completed in \(String(format: "%.2f", elapsed))s
              ✅ succeeded : \(succeeded)
              ❌ failed    : \(failed)
              📹 total     : \(results.count)
            ─────────────────────────────────────────────
            """)

            for result in results where !result.isSuccess {
                print("  ❌ \(result.video.title): \(result.error?.localizedDescription ?? "unknown error")")
            }

            timings.append((concurrency: concurrency, elapsed: elapsed, succeeded: succeeded, failed: failed))

            #expect(succeeded > 0, "Expected at least one successful preview at concurrency \(concurrency)")
        }

        // ── 4. Final comparison ──────────────────────────────────────────────
        let baseline = timings.first?.elapsed ?? 0
        print("""

        ═════════════════════════════════════════════════════════════
        🏁 Concurrency comparison — \(videos.count) video(s)
        ─────────────────────────────────────────────────────────────
         concurrency │   elapsed   │  speedup vs c=1  │  ✅  │  ❌
        ─────────────┼─────────────┼──────────────────┼──────┼──────
        """)
        for t in timings {
            let speedup = baseline > 0 ? baseline / t.elapsed : 0
            let conc    = String(format: "%11d", t.concurrency)
            let secs    = String(format: "%9.2fs", t.elapsed)
            let sp      = String(format: "%14.2fx", speedup)
            let ok      = String(format: "%4d", t.succeeded)
            let ko      = String(format: "%4d", t.failed)
            print(" \(conc) │ \(secs)   │ \(sp)   │ \(ok) │ \(ko)")
        }
        print("═════════════════════════════════════════════════════════════")
    }
}

private final class ProgressBucketTracker: @unchecked Sendable {
    private var buckets: [String: Int] = [:]
    private let lock = NSLock()

    func shouldReport(key: String, bucket: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if (buckets[key] ?? -1) < bucket {
            buckets[key] = bucket
            return true
        }
        return false
    }
}
