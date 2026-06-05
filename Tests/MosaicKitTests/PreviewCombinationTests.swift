import Foundation
import AVFoundation
import Testing
@testable import MosaicKit

// MARK: - Result

private struct PreviewComboResult: Sendable {
    let comboIndex: Int
    let comboName: String
    let videoFilename: String
    let phase: Int
    let elapsed: TimeInterval
    let outputURL: URL?
    let errorDescription: String?
    var succeeded: Bool { errorDescription == nil }
}

// MARK: - Progress reporter

private actor PreviewProgressReporter {
    private let total: Int
    private var completed = 0

    init(total: Int) { self.total = total }

    func record(_ result: PreviewComboResult) {
        completed += 1
        if result.succeeded {
            print(String(format: "[%5d/%5d] ✅ P%d %-22@ %-56@ %.1fs",
                         completed, total, result.phase,
                         result.videoFilename as NSString,
                         result.comboName as NSString,
                         result.elapsed))
        } else {
            print(String(format: "[%5d/%5d] ❌ P%d %-22@ %-56@ %@",
                         completed, total, result.phase,
                         result.videoFilename as NSString,
                         result.comboName as NSString,
                         result.errorDescription ?? "unknown"))
        }
        fflush(stdout)
    }
}

// MARK: - Combination config descriptor

private struct PreviewComboConfig: Sendable {
    let index: Int
    let targetDuration: TimeInterval
    let density: DensityConfig
    let includeAudio: Bool
    /// Selects the export engine for this combination.
    let exportMode: PreviewExportMode
    /// Preset used when `exportMode == .native`. `nil` → quality-derived.
    let nativePreset: nativeExportPreset?
    /// Preset used when `exportMode == .sjs`. `nil` → quality-derived.
    let sjsPreset: SjSExportPreset?
    /// Encoding options forwarded to ffmpeg when `exportMode == .ffmpeg`.
    /// `nil` → derived from `compressionQuality` via `FFmpegEncodingOptions.from(quality:format:)`.
    let ffmpegOptions: FFmpegEncodingOptions?
    let minimumExtractDuration: TimeInterval
    let maximumPlaybackSpeed: Double

    // MARK: FFmpeg binary discovery

    /// Resolves the ffmpeg binary path from, in order:
    ///  1. `FFMPEG_PATH` environment variable
    ///  2. `/opt/homebrew/bin/ffmpeg`  (Apple Silicon Homebrew)
    ///  3. `/usr/local/bin/ffmpeg`     (Intel Homebrew / custom installs)
    ///  4. `/usr/bin/ffmpeg`           (system, rare)
    ///
    /// Returns `nil` when no executable is found; FFmpeg combos are silently
    /// omitted from the matrix in that case.
    static var ffmpegBinaryPath: String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FFMPEG_PATH"],
           fm.isExecutableFile(atPath: env) { return env }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: Short name

    var shortName: String {
        let dur   = "\(Int(targetDuration))s"
        let dens  = density.name.lowercased()
        let audio = includeAudio ? "aud" : "noaud"
        let exportTag: String
        switch exportMode {
        case .native:
            let preset = (nativePreset?.displayString ?? "auto").replacingOccurrences(of: " ", with: "_")
            exportTag = "nat_\(preset)"
        case .sjs:
            let preset = (sjsPreset?.displayString ?? "def").replacingOccurrences(of: " ", with: "_")
            exportTag = "sjs_\(preset)"
        case .ffmpeg:
            let codec = ffmpegOptions?.videoCodec.rawValue ?? "auto"
            let crf   = ffmpegOptions?.crf.map { "crf\($0)" } ?? "qdef"
            exportTag = "ffmpeg_\(codec)_\(crf)"
        }
        let minD = "min\(numStr(minimumExtractDuration))s"
        let maxS = "max\(numStr(maximumPlaybackSpeed))x"
        return String(format: "%04d_%@_%@_%@_%@_%@_%@",
                      index, dur, dens, audio, exportTag, minD, maxS)
    }

    private func numStr(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: "p")
    }

    // MARK: Config builder

    /// Build a `PreviewConfiguration` that writes output directly to `outputDirectory`
    /// (no "movieprev" subfolder) and skips files that already exist.
    func makeConfig(outputDirectory: URL) -> PreviewConfiguration {
        var config = PreviewConfiguration(
            targetDuration: targetDuration,
            minimumExtractDuration: minimumExtractDuration,
            maximumPlaybackSpeed: maximumPlaybackSpeed,
            density: density,
            format: .mp4,
            includeAudio: includeAudio,
            outputDirectory: outputDirectory,
            fullPathInName: false,
            compressionQuality: 0.8,
            exportMode: exportMode,
            exportPresetName: nativePreset,
            sjSExportPresetName: sjsPreset,
            ffmpegBinaryPath: exportMode == .ffmpeg ? Self.ffmpegBinaryPath : nil,
            ffmpegTempFolder: nil,   // auto-create under system temp
            ffmpegEncodingOptions: ffmpegOptions
        )
        config.outputDirectoryTemplate = "{root}"
        config.overwrite = false
        return config
    }
}

// MARK: - Combination matrix builder

private extension PreviewComboConfig {

    /// Builds all parameter combinations across three export engines.
    ///
    /// The shared axes are:
    /// - `targetDuration`          [60 s, 120 s]              ×2
    /// - `density`                 [S, XXS]                   ×2
    /// - `includeAudio`            [true]                     ×1
    /// - `minimumExtractDuration`  [1.0 s, 3.0 s]             ×2
    /// - `maximumPlaybackSpeed`    [1.2×, 1.5×, 2.0×]         ×3
    ///   → 24 base combinations per export variant
    ///
    /// Per export engine:
    /// - **Native** (`.native`)  ×2 presets → 48 combos
    /// - **SJS**    (`.sjs`)     ×1 preset  → 24 combos
    /// - **FFmpeg** (`.ffmpeg`)  ×2 options → 48 combos
    ///   (only added when an ffmpeg binary is available; silently omitted otherwise)
    ///
    /// Total **with** ffmpeg: **120** | without ffmpeg: **72**
    ///
    /// Enable with:
    /// ```bash
    /// PREVIEW_COMBO_RUN=1 swift test --filter PreviewCombinationTests
    /// # Optionally override the ffmpeg path:
    /// FFMPEG_PATH=/opt/homebrew/bin/ffmpeg PREVIEW_COMBO_RUN=1 swift test --filter PreviewCombinationTests
    /// ```
    static func makeAll() -> [PreviewComboConfig] {
        let durations:   [TimeInterval]          = [60, 120]
        let densities:   [DensityConfig]         = [.s, .xxs]
        let audioValues: [Bool]                  = [true]
        let minDurations:[TimeInterval]          = [1.0, 3.0]
        let maxSpeeds:   [Double]                = [1.2, 1.5, 2.0]

        let nativePresets: [nativeExportPreset]  = [
            .AVAssetExportPresetMediumQuality,
            .AVAssetExportPresetLowQuality
        ]
        let sjsPresets: [SjSExportPreset]        = [.h264_lowAutoLevel]

        // Two representative ffmpeg presets: H.264 fast (lighter) and HEVC medium (higher quality)
        let ffmpegOptionsList: [FFmpegEncodingOptions] = [
            FFmpegEncodingOptions(
                videoCodec: .h264, crf: 23, speedPreset: .fast,   maxResolution: ._1080p,
                audioCodec: .aac, audioBitrate: "128k"
            ),
            FFmpegEncodingOptions(
                videoCodec: .hevc, crf: 22, speedPreset: .medium, maxResolution: ._1080p,
                audioCodec: .aac, audioBitrate: "128k"
            ),
        ]

        let ffmpegPath = ffmpegBinaryPath  // nil → omit FFmpeg branch
        if ffmpegPath == nil {
            print("⚠️  ffmpeg not found — FFmpeg combinations will be skipped.")
            print("    Set FFMPEG_PATH or install via Homebrew (`brew install ffmpeg`).\n")
        }

        var configs: [PreviewComboConfig] = []
        var idx = 1

        for dur in durations {
            for dens in densities {
                for audio in audioValues {
                    for minDur in minDurations {
                        for maxSpd in maxSpeeds {

                            // --- Native export ---
                            for preset in nativePresets {
                                configs.append(PreviewComboConfig(
                                    index: idx, targetDuration: dur, density: dens,
                                    includeAudio: audio,
                                    exportMode: .native,
                                    nativePreset: preset, sjsPreset: nil, ffmpegOptions: nil,
                                    minimumExtractDuration: minDur, maximumPlaybackSpeed: maxSpd
                                ))
                                idx += 1
                            }

                            // --- SJS export ---
                            for preset in sjsPresets {
                                configs.append(PreviewComboConfig(
                                    index: idx, targetDuration: dur, density: dens,
                                    includeAudio: audio,
                                    exportMode: .sjs,
                                    nativePreset: nil, sjsPreset: preset, ffmpegOptions: nil,
                                    minimumExtractDuration: minDur, maximumPlaybackSpeed: maxSpd
                                ))
                                idx += 1
                            }

                            // --- FFmpeg export (only when binary is available) ---
                            if ffmpegPath != nil {
                                for options in ffmpegOptionsList {
                                    configs.append(PreviewComboConfig(
                                        index: idx, targetDuration: dur, density: dens,
                                        includeAudio: audio,
                                        exportMode: .ffmpeg,
                                        nativePreset: nil, sjsPreset: nil, ffmpegOptions: options,
                                        minimumExtractDuration: minDur, maximumPlaybackSpeed: maxSpd
                                    ))
                                    idx += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        return configs
    }
}

// MARK: - Timing / failure report

private func previewTimingSummary(results: [PreviewComboResult], label: String) -> String {
    let ok  = results.filter(\.succeeded)
    let bar = String(repeating: "═", count: 72)
    var out = "Preview Combination Test — \(label)\n\(bar)\n\n"

    // Per-mode breakdown
    let byMode: [(String, [PreviewComboResult])] = [
        ("native", results.filter { $0.comboName.contains("_nat_") }),
        ("sjs",    results.filter { $0.comboName.contains("_sjs_") }),
        ("ffmpeg", results.filter { $0.comboName.contains("_ffmpeg_") }),
    ]
    let modeSummary = byMode
        .filter { !$0.1.isEmpty }
        .map { name, rs in
            let s = rs.filter(\.succeeded).count
            return "\(name): \(s)/\(rs.count)"
        }
        .joined(separator: "  |  ")

    out += "Runs    : \(results.count) total  |  \(ok.count) succeeded  |  \(results.count - ok.count) failed\n"
    out += "By mode : \(modeSummary)\n"

    guard !ok.isEmpty else { out += "\nNo successful runs.\n"; return out }

    out += String(format: "Wall    : %.0f s\n\n", ok.map(\.elapsed).reduce(0, +))

    // Per-video breakdown
    var vBuckets: [String: [TimeInterval]] = [:]
    for r in ok { vBuckets[r.videoFilename, default: []].append(r.elapsed) }
    out += "PER-VIDEO\n" + String(repeating: "─", count: 52) + "\n"
    for vid in vBuckets.keys.sorted() {
        let ts = vBuckets[vid]!
        let mean = ts.reduce(0, +) / Double(ts.count)
        out += String(format: "  %-24@  n=%4d  mean=%6.1fs  min=%5.1fs  max=%6.1fs\n",
                      vid as NSString, ts.count, mean, ts.min()!, ts.max()!)
    }
    out += "\n"

    // Per-mode timing
    out += "PER-MODE (successful runs)\n" + String(repeating: "─", count: 52) + "\n"
    for (name, rs) in byMode {
        let okRs = rs.filter(\.succeeded)
        guard !okRs.isEmpty else { continue }
        let ts   = okRs.map(\.elapsed)
        let mean = ts.reduce(0, +) / Double(ts.count)
        out += String(format: "  %-8@  n=%4d  mean=%6.1fs  min=%5.1fs  max=%6.1fs\n",
                      name as NSString, okRs.count, mean, ts.min()!, ts.max()!)
    }
    out += "\n"

    // Slowest 10
    let slowest = ok.sorted { $0.elapsed > $1.elapsed }.prefix(10)
    out += "SLOWEST 10\n" + String(repeating: "─", count: 52) + "\n"
    for r in slowest {
        out += String(format: "  %6.1fs  %-22@ %@\n", r.elapsed, r.videoFilename as NSString, r.comboName)
    }
    out += "\n"

    // Failures
    let failed = results.filter { !$0.succeeded }
    if !failed.isEmpty {
        out += "FAILED (\(failed.count))\n" + String(repeating: "─", count: 52) + "\n"
        for r in failed {
            out += "  P\(r.phase) [\(r.videoFilename)] \(r.comboName)\n"
            out += "  → \(r.errorDescription ?? "unknown error")\n\n"
        }
    }

    return out
}

// MARK: - Suite

/// Exhaustive preview-generation parameter combination tests covering all three export engines.
///
/// Runs three ordered phases against real video files in `/Volumes/Ext-Photos5/TestPreviews`.
/// All output is saved to `/Volumes/Ext-Photos5/TestPreviews/<timestamp>/` and is **not deleted**
/// after the test completes.
///
/// ## Combination matrix
///
/// Shared axes (24 base combinations):
///
/// | Parameter                | Values                      |
/// |:-------------------------|:----------------------------|
/// | `targetDuration`         | 60 s, 120 s                 |
/// | `density`                | S, XXS                      |
/// | `includeAudio`           | true                        |
/// | `minimumExtractDuration` | 1.0 s, 3.0 s                |
/// | `maximumPlaybackSpeed`   | 1.2×, 1.5×, 2.0×            |
///
/// Per export engine:
///
/// | Engine   | Variants                                 | Combos |
/// |:---------|:-----------------------------------------|-------:|
/// | Native   | MediumQuality, LowQuality                | 48     |
/// | SJS      | h264_lowAutoLevel                        | 24     |
/// | FFmpeg ¹ | H.264/CRF23/fast, HEVC/CRF22/medium      | 48     |
///
/// ¹ FFmpeg combos are included only when an `ffmpeg` binary is discoverable.
///   Override the path via `FFMPEG_PATH=/path/to/ffmpeg`.
///
/// Total **with** ffmpeg: **120** | without: **72**
///
/// ## Phases
/// - **Phase 1**: `TestB.mp4` — all combos, sequential
/// - **Phase 2**: `TestB.mp4` → `DDSC-031.mp4` — all combos each, sequential
/// - **Phase 3**: `testA.mp4` / `TestB.mp4` / `TestC.mp4` / `DDSC-031.mp4` — 4 files concurrent
///
/// ## Run
/// ```bash
/// PREVIEW_COMBO_RUN=1 swift test --filter PreviewCombinationTests
/// # With a custom ffmpeg path:
/// FFMPEG_PATH=/opt/homebrew/bin/ffmpeg PREVIEW_COMBO_RUN=1 swift test --filter PreviewCombinationTests
/// ```
///
/// The test is silently skipped when `PREVIEW_COMBO_RUN` is not set so it does not block CI.
@Suite("Preview Combination Tests", .serialized)
struct PreviewCombinationTests {

    // MARK: Constants

    private static let videoRoot = URL(fileURLWithPath: "/Volumes/Ext-Photos5/TestPreviews")

    /// Timestamp determined once at suite start; all three phases write to the same directory.
    private static let runTimestamp: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }()

    private static let runOutputDirectory: URL =
        videoRoot.appendingPathComponent(runTimestamp)

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PREVIEW_COMBO_RUN"] == "1"
    }

    /// All parameter combinations — built once at suite load.
    /// FFmpeg combos are included only when an ffmpeg binary is found.
    private static let allCombos: [PreviewComboConfig] = PreviewComboConfig.makeAll()

    // MARK: Helpers

    private func url(for filename: String) -> URL {
        Self.videoRoot.appendingPathComponent(filename)
    }

    private func ensureOutputDirectory() throws {
        try FileManager.default.createDirectory(
            at: Self.runOutputDirectory,
            withIntermediateDirectories: true
        )
    }

    private func printHeader(phase: Int, videos: [String], combosPerVideo: Int) {
        let bar = String(repeating: "─", count: 72)
        let ffmpegNote = PreviewComboConfig.ffmpegBinaryPath != nil
            ? "ffmpeg: \(PreviewComboConfig.ffmpegBinaryPath!)"
            : "ffmpeg: not found (FFmpeg combos skipped)"
        print("""

        🎬 Phase \(phase) — \(videos.joined(separator: " → "))
        \(bar)
          Combinations per video : \(combosPerVideo)
          Total runs             : \(combosPerVideo * videos.count)
          Output                 : \(Self.runOutputDirectory.path)
          \(ffmpegNote)
        \(bar)
        """)
    }

    // MARK: - Phase 1 ── TestB.MP4, all combos, sequential

    @Test("Phase 1 – TestB.MP4,  combinations sequential")
    func phase1_singleVideo() async throws {
        guard Self.isEnabled else {
            print("""

            ⚠️  PreviewCombinationTests skipped — PREVIEW_COMBO_RUN is not set.
                Run with:
                  PREVIEW_COMBO_RUN=1 swift test --filter PreviewCombinationTests

            """)
            return
        }

        try ensureOutputDirectory()

        let combos    = Self.allCombos
        let outputDir = Self.runOutputDirectory
        let video     = await VideoInput(url: url(for: "TestB.mp4"))
        let reporter  = PreviewProgressReporter(total: combos.count)

        printHeader(phase: 1, videos: ["TestB.mp4"], combosPerVideo: combos.count)
        print(String(format: "  Video info: %@  %.0fs  %dx%d\n",
                     video.title, video.duration ?? 0,
                     Int(video.width ?? 0), Int(video.height ?? 0)))

        var results: [PreviewComboResult] = []
        results.reserveCapacity(combos.count)
        let generator = PreviewVideoGenerator()

        for combo in combos {
            let config = combo.makeConfig(outputDirectory: outputDir)
            let start  = Date()
            do {
                let outputURL = try await generator.generate(for: video, config: config)
                let r = PreviewComboResult(
                    comboIndex: combo.index, comboName: combo.shortName,
                    videoFilename: "TestB.mp4", phase: 1,
                    elapsed: Date().timeIntervalSince(start),
                    outputURL: outputURL, errorDescription: nil)
                results.append(r)
                await reporter.record(r)
            } catch {
                let r = PreviewComboResult(
                    comboIndex: combo.index, comboName: combo.shortName,
                    videoFilename: "TestB.mp4", phase: 1,
                    elapsed: Date().timeIntervalSince(start),
                    outputURL: nil, errorDescription: error.localizedDescription)
                results.append(r)
                await reporter.record(r)
            }
        }

        let succeeded = results.filter(\.succeeded).count
        print("\n── Phase 1 complete: \(succeeded)/\(results.count) succeeded ──\n")

        let summary = previewTimingSummary(results: results, label: "Phase 1 — TestB.mp4")
        let reportURL = outputDir.appendingPathComponent("phase1_report.txt")
        try summary.write(to: reportURL, atomically: true, encoding: .utf8)
        print(summary)
        print("📄 Report: \(reportURL.path)\n")

        #expect(succeeded > 0, "Phase 1: expected at least one successful preview generation")
    }

    // MARK: - Phase 2 ── TestB.mp4 → DDSC-031.mp4, sequential

    @Test("Phase 2 – TestB.mp4 then DDSC-031.mp4, sequential")
    func phase2_sequentialVideos() async throws {
        guard Self.isEnabled else { return }

        try ensureOutputDirectory()

        let combos    = Self.allCombos
        let outputDir = Self.runOutputDirectory
        let filenames = ["TestB.mp4", "DDSC-031.mp4"]
        let reporter  = PreviewProgressReporter(total: combos.count * filenames.count)

        printHeader(phase: 2, videos: filenames, combosPerVideo: combos.count)

        var allResults: [PreviewComboResult] = []
        allResults.reserveCapacity(combos.count * filenames.count)

        for filename in filenames {
            let video     = await VideoInput(url: url(for: filename))
            let generator = PreviewVideoGenerator()

            print(String(format: "\n  ▶  %@  %.0fs  %dx%d",
                         filename, video.duration ?? 0,
                         Int(video.width ?? 0), Int(video.height ?? 0)))

            for combo in combos {
                let config = combo.makeConfig(outputDirectory: outputDir)
                let start  = Date()
                do {
                    let outputURL = try await generator.generate(for: video, config: config)
                    let r = PreviewComboResult(
                        comboIndex: combo.index, comboName: combo.shortName,
                        videoFilename: filename, phase: 2,
                        elapsed: Date().timeIntervalSince(start),
                        outputURL: outputURL, errorDescription: nil)
                    allResults.append(r)
                    await reporter.record(r)
                } catch {
                    let r = PreviewComboResult(
                        comboIndex: combo.index, comboName: combo.shortName,
                        videoFilename: filename, phase: 2,
                        elapsed: Date().timeIntervalSince(start),
                        outputURL: nil, errorDescription: error.localizedDescription)
                    allResults.append(r)
                    await reporter.record(r)
                }
            }
        }

        let succeeded = allResults.filter(\.succeeded).count
        print("\n── Phase 2 complete: \(succeeded)/\(allResults.count) succeeded ──\n")

        let summary = previewTimingSummary(results: allResults, label: "Phase 2 — TestB.mp4 + DDSC-031.mp4")
        let reportURL = outputDir.appendingPathComponent("phase2_report.txt")
        try summary.write(to: reportURL, atomically: true, encoding: .utf8)
        print(summary)
        print("📄 Report: \(reportURL.path)\n")

        #expect(succeeded > 0, "Phase 2: expected at least one successful preview generation")
    }

    // MARK: - Phase 3 ── testA / TestB / TestC / DDSC-031, concurrent

    @Test("Phase 3 – testA.mp4 / TestB.mp4 / TestC.mp4 / DDSC-031.mp4 concurrent")
    func phase3_concurrentVideos() async throws {
        guard Self.isEnabled else { return }

        try ensureOutputDirectory()

        let combos    = Self.allCombos
        let outputDir = Self.runOutputDirectory
        let filenames = ["testA.mp4", "TestB.mp4", "TestC.mp4", "DDSC-031.mp4"]
        let reporter  = PreviewProgressReporter(total: combos.count * filenames.count)

        printHeader(phase: 3, videos: filenames, combosPerVideo: combos.count)

        // Load all four VideoInputs sequentially (metadata reads are fast)
        var videos: [(filename: String, input: VideoInput)] = []
        for filename in filenames {
            let input = await VideoInput(url: url(for: filename))
            videos.append((filename, input))
            print(String(format: "  ↳ %@  %.0fs  %dx%d",
                         filename, input.duration ?? 0,
                         Int(input.width ?? 0), Int(input.height ?? 0)))
        }
        print("")

        // Four tasks run concurrently; each task processes its video's combos sequentially
        let allResults: [PreviewComboResult] = await withTaskGroup(of: [PreviewComboResult].self) { group in

            for (filename, video) in videos {
                group.addTask {
                    var taskResults: [PreviewComboResult] = []
                    taskResults.reserveCapacity(combos.count)
                    let generator = PreviewVideoGenerator()

                    for combo in combos {
                        let config = combo.makeConfig(outputDirectory: outputDir)
                        let start  = Date()
                        do {
                            let outputURL = try await generator.generate(for: video, config: config)
                            let r = PreviewComboResult(
                                comboIndex: combo.index, comboName: combo.shortName,
                                videoFilename: filename, phase: 3,
                                elapsed: Date().timeIntervalSince(start),
                                outputURL: outputURL, errorDescription: nil)
                            taskResults.append(r)
                            await reporter.record(r)
                        } catch {
                            let r = PreviewComboResult(
                                comboIndex: combo.index, comboName: combo.shortName,
                                videoFilename: filename, phase: 3,
                                elapsed: Date().timeIntervalSince(start),
                                outputURL: nil, errorDescription: error.localizedDescription)
                            taskResults.append(r)
                            await reporter.record(r)
                        }
                    }

                    return taskResults
                }
            }

            var collected: [PreviewComboResult] = []
            for await batch in group { collected.append(contentsOf: batch) }
            return collected
        }

        let succeeded = allResults.filter(\.succeeded).count
        print("\n── Phase 3 complete: \(succeeded)/\(allResults.count) succeeded ──\n")

        let summary = previewTimingSummary(results: allResults, label: "Phase 3 — Concurrent (4 videos)")
        let reportURL = outputDir.appendingPathComponent("phase3_report.txt")
        try summary.write(to: reportURL, atomically: true, encoding: .utf8)
        print(summary)
        print("📄 Report: \(reportURL.path)\n")

        #expect(succeeded > 0, "Phase 3: expected at least one successful preview generation")
    }
}
