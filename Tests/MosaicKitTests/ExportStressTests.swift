import Foundation
import Synchronization
import Testing
@testable import MosaicKit
import MosaicKitWebP

/// Opt-in export stress test (I-26).
///
/// Runs rounds of native preview exports concurrently with encoder-heavy mosaic and HEIC
/// animation jobs, and counts exports whose progress freezes. It found the cause of I-26:
/// exports stall only when the process runs under macOS background scheduling. Run it plain,
/// then under `taskpolicy -b`, to compare:
///
/// ```bash
/// MOSAICKIT_STRESS=10 swift test --filter ExportStressTests
/// MOSAICKIT_STRESS=10 taskpolicy -b swift test --skip-build --filter ExportStressTests
/// ```
///
/// | Variable | Default | Meaning |
/// |---|---|---|
/// | `MOSAICKIT_STRESS` | — (suite disabled) | Number of rounds |
/// | `MOSAICKIT_STRESS_EXPORTS` | `4` | Concurrent preview exports per round |
/// | `MOSAICKIT_STRESS_LOAD` | `3` | Concurrent mosaic/HEIC jobs per round (encoder load) |
/// | `MOSAICKIT_STRESS_STALL` | `30` | Seconds without progress that count as a stall |
/// | `MOSAICKIT_STRESS_SOURCE` | embedded fixture | Folder of videos the exports cycle through |
/// | `MOSAICKIT_STRESS_LEAVE_BACKGROUND` | — | If set, the process leaves background scheduling first |
///
/// No assertion fails on stalls: the counts are the result, printed as `ExportStress RESULT`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOSAICKIT_STRESS"] != nil,
                             "Set MOSAICKIT_STRESS=<rounds> to run"))
struct ExportStressTests {
    init() { MosaicKitWebP.register() }

    @Test func stress() async throws {
        let env = ProcessInfo.processInfo.environment
        let rounds = Int(env["MOSAICKIT_STRESS"] ?? "") ?? 5
        let exportsPerRound = Int(env["MOSAICKIT_STRESS_EXPORTS"] ?? "") ?? 4
        let loadJobs = Int(env["MOSAICKIT_STRESS_LOAD"] ?? "") ?? 3
        let stallLimit = Double(env["MOSAICKIT_STRESS_STALL"] ?? "") ?? 30
        if env["MOSAICKIT_STRESS_LEAVE_BACKGROUND"] != nil { ProcessScheduling.leaveBackground() }
        let background = ProcessScheduling.isBackground
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let base = try await VideoInput(from: url)
        // Optional folder of real videos: exports cycle through them.
        var sources: [VideoInput] = [base]
        if let folder = env["MOSAICKIT_STRESS_SOURCE"] {
            let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
                .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
            sources = []
            for file in files { sources.append(try await VideoInput(from: file)) }
            try #require(!sources.isEmpty, "No mp4/mov/m4v files in MOSAICKIT_STRESS_SOURCE=\(folder)")
            print("ExportStress sources: \(sources.map { "\($0.url.lastPathComponent) \(Int($0.duration ?? 0))s \(Int($0.width ?? 0))x\(Int($0.height ?? 0))" })")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportStress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = Stats()
        for round in 1...rounds {
            let start = ContinuousClock.now
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<exportsPerRound {
                    let source = sources[(round * exportsPerRound + i) % sources.count]
                    group.addTask { await Self.runExport(source.withID(UUID()), root: root, label: "r\(round)e\(i)[\(source.url.lastPathComponent)]", stallLimit: stallLimit, stats: stats) }
                }
                for j in 0..<loadJobs {
                    group.addTask {
                        // A failed load job means less encoder load than intended: count it.
                        do { try await Self.runLoad(base.withID(UUID()), root: root, index: j) }
                        catch { stats.loadFailure("round \(round) load \(j): \(error)") }
                    }
                }
                try await group.waitForAll()
            }
            print("ExportStress round \(round): \(start.duration(to: .now)) — \(stats.summary)")
        }
        print("ExportStress RESULT backgroundScheduling=\(background): \(stats.summary)")
        for line in stats.stallDetails { print("ExportStress STALL \(line)") }
    }

    private static func runExport(_ video: VideoInput, root: URL, label: String, stallLimit: Double, stats: Stats) async {
        let outputDirectory = root.appendingPathComponent(UUID().uuidString)
        var config = PreviewConfiguration(targetDuration: 10, density: .xxl, format: .mp4, includeAudio: false,
                                          outputDirectory: outputDirectory, exportMode: .native,
                                          exportPresetName: .AVAssetExportPresetMediumQuality,
                                          enableAppLifecycleMonitor: false, enableExportRetry: false)
        config.overwrite = true
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let progress = LastProgress()
        let generator = PreviewVideoGenerator()
        await generator.setProgressHandler(for: video) { progress.record($0.progress) }
        let job = Task { try await generator.generate(for: video, config: config) }
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let (value, idle) = progress.snapshot
                if value >= 0.1, idle >= stallLimit {   // only count stalls once encoding started
                    stats.stall("\(label) frozen at \(Int(value * 100))% (overall) for \(Int(idle))s")
                    await generator.cancel(for: video)
                    job.cancel()
                    return
                }
            }
        }
        let result = await job.result
        watcher.cancel()
        switch result {
        case .success: stats.success()
        case .failure(let error): if !stats.wasStalled(label) { stats.failure("\(label): \(error)") }
        }
    }

    private static func runLoad(_ video: VideoInput, root: URL, index: Int) async throws {
        let outputDirectory = root.appendingPathComponent("load\(index)-\(UUID().uuidString)")
        var config = MosaicConfiguration(width: 5120, density: .m, format: .heif, outputdirectory: outputDirectory)
        config.overwrite = true
        config.gifMode = index.isMultiple(of: 2) ? .gifOnly : .withMosaic
        config.animatedFormat = .heic
        config.gifSize = .large
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        _ = try await MetalMosaicGenerator().generate(for: video, config: config)
    }
}

private final class LastProgress: Sendable {
    private let state = Mutex<(Double, ContinuousClock.Instant)>((0, .now))
    func record(_ value: Double) { state.withLock { if value != $0.0 { $0 = (value, .now) } } }
    var snapshot: (Double, Double) {
        state.withLock { s in
            let d = s.1.duration(to: .now)
            return (s.0, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
    }
}

private final class Stats: Sendable {
    private let state = Mutex<(ok: Int, stalls: [String], failures: [String], loadFailures: [String])>((0, [], [], []))
    func success() { state.withLock { $0.ok += 1 } }
    func stall(_ s: String) { state.withLock { $0.stalls.append(s) } }
    func failure(_ s: String) { state.withLock { $0.failures.append(s) } }
    func loadFailure(_ s: String) { state.withLock { $0.loadFailures.append(s) } }
    func wasStalled(_ label: String) -> Bool { state.withLock { $0.stalls.contains { $0.hasPrefix(label + " ") } } }
    var summary: String {
        state.withLock { "ok \($0.ok), stalls \($0.stalls.count), other failures \($0.failures.count), load failures \($0.loadFailures.count)" }
    }
    var stallDetails: [String] {
        state.withLock { $0.stalls + $0.failures.map { "FAIL " + $0 } + $0.loadFailures.map { "LOAD FAIL " + $0 } }
    }
}
