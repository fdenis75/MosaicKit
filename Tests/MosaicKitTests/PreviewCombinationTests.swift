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
    let useNativeExport: Bool
    let nativePreset: nativeExportPreset?
    let sjsPreset: SjSExportPreset?
    let minimumExtractDuration: TimeInterval
    let maximumPlaybackSpeed: Double

    var shortName: String {
        let dur = "\(Int(targetDuration))s"
        let dens = density.name.lowercased()
        let audio = includeAudio ? "aud" : "noaud"
        let exportTag: String
        if useNativeExport {
            let preset = (nativePreset?.displayString ?? "auto").replacingOccurrences(of: " ", with: "_")
            exportTag = "nat_\(preset)"
        } else {
            let preset = (sjsPreset?.displayString ?? "def").replacingOccurrences(of: " ", with: "_")
            exportTag = "sjs_\(preset)"
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

    /// Build a PreviewConfiguration that writes output directly to `outputDirectory`
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
            useNativeExport: useNativeExport,
            exportPresetName: nativePreset,
            sjSExportPresetName: sjsPreset
        )
        config.outputDirectoryTemplate = "{root}"
        config.overwrite = false
        return config
    }
}

// MARK: - Combination matrix builder

private extension PreviewComboConfig {

    /// Builds all 540 combinations.
    ///
    /// Matrix:
    /// - duration              [30s, 90s]                             ×2
    /// - density               [XXL, L, XS]                          ×3
    /// - includeAudio          [true, false]                          ×2
    /// - minimumExtractDuration[1.5s, 3s, 5s]                        ×3
    /// - maximumPlaybackSpeed  [1.0, 1.5, 2.0]                       ×3
    /// - useNativeExport=true  nativePresets [HEVC_Hi, H264_Med, H264-Lo]  →  324
    /// - useNativeExport=false sjsPresets    [hevc, h264_lowAutoLevel]     →  216
    ///                                                          Total: 540
    static func makeAll() -> [PreviewComboConfig] {
        let durations: [TimeInterval]            = [60, 120]
        let densities: [DensityConfig]           = [.s, .xxs]
        let audioValues: [Bool]                  = [true]
        let nativePresets: [nativeExportPreset]  = [
            .AVAssetExportPresetMediumQuality,
            .AVAssetExportPresetLowQuality
        ]
        let sjsPresets: [SjSExportPreset]        = [.h264_lowAutoLevel]
        let minDurations: [TimeInterval]         = [1.0, 3.0]
        let maxSpeeds: [Double]                  = [1.2, 1.5, 2.0 ]

        var configs: [PreviewComboConfig] = []
        var idx = 1

        for dur in durations {
            for dens in densities {
                for audio in audioValues {
                    for minDur in minDurations {
                        for maxSpd in maxSpeeds {
                            // Native export branch
                            for preset in nativePresets {
                                configs.append(PreviewComboConfig(
                                    index: idx, targetDuration: dur, density: dens,
                                    includeAudio: audio, useNativeExport: true,
                                    nativePreset: preset, sjsPreset: nil,
                                    minimumExtractDuration: minDur, maximumPlaybackSpeed: maxSpd
                                ))
                                idx += 1
                            }
                            // SJS export branch
                            for preset in sjsPresets {
                                configs.append(PreviewComboConfig(
                                    index: idx, targetDuration: dur, density: dens,
                                    includeAudio: audio, useNativeExport: false,
                                    nativePreset: nil, sjsPreset: preset,
                                    minimumExtractDuration: minDur, maximumPlaybackSpeed: maxSpd
                                ))
                                idx += 1
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
    let ok = results.filter(\.succeeded)
    let bar = String(repeating: "═", count: 72)
    var out = "Preview Combination Test — \(label)\n\(bar)\n\n"
    out += "Runs    : \(results.count) total  |  \(ok.count) succeeded  |  \(results.count - ok.count) failed\n"

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

/// Exhaustive preview-generation parameter combination tests.
///
/// Runs three ordered phases against real video files in `/Volumes/Ext-Photos5/TestPreviews`.
/// All output is saved to `/Volumes/Ext-Photos5/TestPreviews/<timestamp>/` and is **not deleted**
/// after the test completes.
///
/// ## Combination matrix (540 per video)
/// | Parameter                | Values                                          |
/// |:-------------------------|:------------------------------------------------|
/// | `targetDuration`         | 30 s, 90 s                                      |
/// | `density`                | XXL, L, XS                                      |
/// | `includeAudio`           | true, false                                     |
/// | `minimumExtractDuration` | 1.5 s, 3 s, 5 s                                 |
/// | `maximumPlaybackSpeed`   | 1.0, 1.5, 2.0                                   |
/// | native presets (×3)      | HEVC_Hi, H264_Med, H264-Lo → **324 combos**     |
/// | SJS presets (×2)         | hevc, h264_lowAutoLevel    → **216 combos**     |
///
/// ## Phases
/// - **Phase 1**: `DJI_0080.MP4` — all 540 combos, sequential
/// - **Phase 2**: `TestB.mp4` → `DDSC-031.mp4` — 540 combos each, sequential
/// - **Phase 3**: `testA.mp4` / `TestB.mp4` / `TestC.mp4` / `DDSC-031.mp4` — 4 files concurrent,
///   each file's 540 combos run sequentially within its own task
///
/// ## Run
/// ```bash
/// PREVIEW_COMBO_RUN=1 swift test --filter PreviewCombinationTests
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

    /// All 540 parameter combinations — built once, shared across all phases.
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
        print("""

        🎬 Phase \(phase) — \(videos.joined(separator: " → "))
        \(bar)
          Combinations per video : \(combosPerVideo)
          Total runs             : \(combosPerVideo * videos.count)
          Output                 : \(Self.runOutputDirectory.path)
        \(bar)
        """)
    }

    // MARK: - Phase 1 ── DJI_0080.MP4, all 540 combos, sequential

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

        let combos   = Self.allCombos
        let outputDir = Self.runOutputDirectory
        let video    = await VideoInput(url: url(for: "TestB.mp4"))
        let reporter = PreviewProgressReporter(total: combos.count)

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

        // Four tasks run concurrently; each task processes its video's 540 combos sequentially
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
            for await batch in group {
                collected.append(contentsOf: batch)
            }
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
