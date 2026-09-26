import Foundation
import Testing
@testable import MosaicKit
import MosaicKitWebP

/// Opt-in throughput benchmark (implementation plan P-1).
///
/// Every change tagged ⚡ in `codebase-analysis-docs/IMPLEMENTATION_PLAN.md` (mosaic or animation
/// pipeline, batch scheduling) must be measured with this suite on `main` and on the PR branch,
/// on the same machine and the same videos. Paste both tables into the PR description.
///
/// ## Environment variables
///
/// | Variable | Default | Meaning |
/// |---|---|---|
/// | `MOSAICKIT_BENCHMARK` | — (suite disabled) | Folder of videos, or a single video file |
/// | `MOSAICKIT_BENCHMARK_RUNS` | `3` | Timed runs per scenario, after one untimed warm-up run |
/// | `MOSAICKIT_BENCHMARK_CONCURRENCY` | `1,0` | Coordinator concurrency limits to measure (`0` = automatic) |
/// | `MOSAICKIT_BENCHMARK_JSON` | — | Optional path; all measurements are also written there as JSON |
///
/// ```bash
/// MOSAICKIT_BENCHMARK=/path/to/videos swift test -c release --filter BenchmarkTests
/// ```
///
/// There are no assertions on timing: machines differ, so only same-machine before/after
/// comparisons are meaningful. The suite fails only when a generation fails.
@Suite("Throughput benchmark (opt-in)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MOSAICKIT_BENCHMARK"] != nil,
                "Set MOSAICKIT_BENCHMARK=/path/to/videos to run"))
struct BenchmarkTests {

    init() {
        MosaicKitWebP.register()
    }

    /// A fixed configuration measured on every run. Keep these stable across PRs so results
    /// stay comparable; add new scenarios instead of editing existing ones.
    private struct Scenario: Sendable {
        let name: String
        let width: Int
        let density: DensityConfig
        let gifMode: GifCreationMode
        let animatedFormat: AnimatedFormat
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "mosaic-5120-M", width: 5120, density: .m, gifMode: .disabled, animatedFormat: .gif),
        Scenario(name: "mosaic-10000-XS", width: 10_000, density: .xs, gifMode: .disabled, animatedFormat: .gif),
        Scenario(name: "anim-gif-small", width: 5120, density: .m, gifMode: .gifOnly, animatedFormat: .gif),
        Scenario(name: "anim-webp-small", width: 5120, density: .m, gifMode: .gifOnly, animatedFormat: .webp),
    ]

    private struct Measurement: Codable, Sendable {
        let scenario: String
        let concurrency: Int
        let videos: Int
        let runSeconds: [Double]
        let medianSeconds: Double
        let sourceSecondsPerSecond: Double
        let inputMBPerSecond: Double
        let outputMB: Double
        let processPeakRSSMB: Double
    }

    @Test("Mosaic and animated export throughput")
    func throughput() async throws {
        let env = ProcessInfo.processInfo.environment
        let videos = try await loadVideos(from: try #require(env["MOSAICKIT_BENCHMARK"]))
        try #require(!videos.isEmpty, "No readable videos found in MOSAICKIT_BENCHMARK")
        let runs = try Self.parseRuns(env["MOSAICKIT_BENCHMARK_RUNS"])
        let concurrencies = try Self.parseConcurrencies(env["MOSAICKIT_BENCHMARK_CONCURRENCY"])

        let sourceSeconds = videos.compactMap(\.duration).reduce(0, +)
        let inputMB = Double(videos.compactMap(\.fileSize).reduce(0, +)) / 1_048_576

        var measurements: [Measurement] = []
        for scenario in Self.scenarios {
            for concurrency in concurrencies {
                var timings: [Double] = []
                var outputMB = 0.0
                // Run 0 is an untimed warm-up (disk cache, Metal pipeline compilation).
                for run in 0...runs {
                    let (seconds, bytes) = try await runBatch(videos: videos, scenario: scenario, concurrency: concurrency)
                    if run > 0 { timings.append(seconds); outputMB = Double(bytes) / 1_048_576 }
                }
                let median = Self.median(timings)
                measurements.append(Measurement(
                    scenario: scenario.name,
                    concurrency: concurrency,
                    videos: videos.count,
                    runSeconds: timings,
                    medianSeconds: median,
                    sourceSecondsPerSecond: sourceSeconds / median,
                    inputMBPerSecond: inputMB / median,
                    outputMB: outputMB,
                    processPeakRSSMB: Self.processPeakRSSMB()
                ))
            }
        }

        print(Self.markdownTable(measurements, videos: videos.count, sourceSeconds: sourceSeconds, inputMB: inputMB))
        if let jsonPath = env["MOSAICKIT_BENCHMARK_JSON"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(measurements).write(to: URL(fileURLWithPath: jsonPath))
        }
    }

    // MARK: - Helpers

    /// `MOSAICKIT_BENCHMARK_RUNS`: a positive integer, default 3. Invalid values fail the run
    /// instead of silently measuring something else.
    private static func parseRuns(_ raw: String?) throws -> Int {
        guard let raw else { return 3 }
        guard let runs = Int(raw.trimmingCharacters(in: .whitespaces)), runs >= 1 else {
            throw BenchmarkError.invalidSetting("MOSAICKIT_BENCHMARK_RUNS", raw)
        }
        return runs
    }

    /// `MOSAICKIT_BENCHMARK_CONCURRENCY`: comma-separated integers ≥ 0 (`0` = automatic), default
    /// `1,0`. A typo must not silently yield an empty report, and a negative limit would make the
    /// coordinator wait forever, so every entry has to parse.
    private static func parseConcurrencies(_ raw: String?) throws -> [Int] {
        guard let raw else { return [1, 0] }
        let values = raw.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ ($0 ?? -1) >= 0 }) else {
            throw BenchmarkError.invalidSetting("MOSAICKIT_BENCHMARK_CONCURRENCY", raw)
        }
        return values.compactMap { $0 }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func loadVideos(from path: String) async throws -> [VideoInput] {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BenchmarkError.pathNotFound(path)
        }
        if isDirectory.boolValue {
            return try await discoverVideos(in: url).sorted { $0.url.path < $1.url.path }
        }
        return [try await VideoInput(from: url)]
    }

    /// Runs one batch into a fresh temporary directory and returns (wall seconds, output bytes).
    private func runBatch(videos: [VideoInput], scenario: Scenario, concurrency: Int) async throws -> (Double, Int64) {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        var config = MosaicConfiguration(
            width: scenario.width,
            density: scenario.density,
            format: .heif,
            layout: LayoutConfiguration(aspectRatio: .widescreen, layoutType: .custom),
            includeMetadata: true,
            useAccurateTimestamps: false,
            compressionQuality: 0.4,
            outputdirectory: outputDir
        )
        config.gifMode = scenario.gifMode
        config.gifSize = .small
        config.animatedFormat = scenario.animatedFormat
        config.overwrite = true

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: concurrency)
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { _ in }
        let elapsed = start.duration(to: clock.now)

        for result in results where !result.isSuccess {
            Issue.record("\(scenario.name): \(result.video.title) failed: \(result.error?.localizedDescription ?? "unknown")")
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds, Self.directorySize(outputDir))
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Peak resident memory of the whole test process so far (monotonic). Run the suite on its
    /// own (`--filter BenchmarkTests`) for this to mean anything.
    private static func processPeakRSSMB() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / 1_048_576 // bytes on Darwin
    }

    private static func markdownTable(_ rows: [Measurement], videos: Int, sourceSeconds: Double, inputMB: Double) -> String {
        func f(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
        var lines = [
            "",
            "MosaicKit benchmark — \(videos) video(s), \(f(sourceSeconds / 60, 1)) min of source, \(f(inputMB, 0)) MB input",
            "",
            "| Scenario | Concurrency | Median (s) | Runs (s) | Source s/s | Input MB/s | Output MB | Peak RSS (MB) |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for r in rows {
            let concurrency = r.concurrency == 0 ? "auto" : String(r.concurrency)
            let runs = r.runSeconds.map { f($0) }.joined(separator: ", ")
            lines.append("| \(r.scenario) | \(concurrency) | \(f(r.medianSeconds)) | \(runs) | \(f(r.sourceSecondsPerSecond, 1)) | \(f(r.inputMBPerSecond, 1)) | \(f(r.outputMB, 1)) | \(f(r.processPeakRSSMB, 0)) |")
        }
        return lines.joined(separator: "\n")
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case pathNotFound(String)
    case invalidSetting(String, String)

    var description: String {
        switch self {
        case .pathNotFound(let path): return "MOSAICKIT_BENCHMARK path not found: \(path)"
        case .invalidSetting(let name, let value): return "Invalid \(name) value: \(value)"
        }
    }
}
