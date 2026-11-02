import Foundation

/// The single place where the tests read environment variables. No test hard-codes a path to a
/// local or remote file: every external input comes from here, and every variable is documented
/// in this table (also summarised in the README "Test environment" section).
///
/// ## Inputs: files and folders
///
/// | Variable | Kind | Used by |
/// |---|---|---|
/// | `MOSAICKIT_LOCALVIDEO1` … `MOSAICKIT_LOCALVIDEO4` | video file | `CombinationTests` (1), `PreviewCombinationTests` (1 in phase 1; 1–2 in phase 2; 1–4 in phase 3), `BenchmarkTests` (all set ones, when `MOSAICKIT_LOCALFOLDER` is unset) |
/// | `MOSAICKIT_LOCALFOLDER` | folder of videos | `MosaicGeneratorCoordinatorTests`, `MosaicCancellationTests`, `PreviewCancellationTests`, `PreviewCoordinatorTests`, `ExportStressTests`, `BenchmarkTests` |
/// | `MOSAICKIT_LOCALPLAYLIST` | `.m3u8` / `.m3u` file | `PlaylistMosaicTests` |
/// | `MOSAICKIT_FFMPEG_PATH` | executable | every ffmpeg test (falls back to Homebrew / system locations) |
///
/// ## Outputs
///
/// | Variable | Kind | Used by |
/// |---|---|---|
/// | `MOSAICKIT_OUTPUTFOLDER` | folder (created if missing) | `CombinationTests`, `PreviewCombinationTests`, `PreviewCoordinatorTests`, `PlaylistMosaicTests`, `BenchmarkTests` (`benchmark.json`). Unset: a temporary directory. |
///
/// ## Remote files
///
/// None. Every URL in the tests (`https://host/…`, `dl.example.com`) is a synthetic string that is
/// parsed but never fetched. `PlaylistMosaicTests` can reach remote files only if the playlist
/// named by `MOSAICKIT_LOCALPLAYLIST` lists them.
///
/// ## Run selection and tuning (not paths)
///
/// | Variable | Default | Effect |
/// |---|---|---|
/// | `MOSAICKIT_SUITE_MODE` | unset | `none` skips media-folder and extended suites (CI). |
/// | `MOSAICKIT_SKIP_ANIMATED` | unset | `1` skips the slow animated-export tests (CI push / PR). |
/// | `MOSAICKIT_BENCHMARK` | unset | `1` enables `BenchmarkTests`; it also needs `MOSAICKIT_LOCALFOLDER` or `MOSAICKIT_LOCALVIDEO1`. |
/// | `MOSAICKIT_BENCHMARK_RUNS` | `3` | Timed runs per scenario. |
/// | `MOSAICKIT_BENCHMARK_CONCURRENCY` | `1,0` | Coordinator limits to measure (`0` = automatic). |
/// | `MOSAICKIT_BENCHMARK_GRID` | unset | `1` adds the fixed-grid scenarios. |
/// | `MOSAICKIT_BENCHMARK_UNEVEN` | unset | `1` adds the uneven-layout scenarios. |
/// | `MOSAICKIT_STRESS` | unset | Number of rounds; enables `ExportStressTests`. |
/// | `MOSAICKIT_STRESS_EXPORTS` | `4` | Concurrent preview exports per round. |
/// | `MOSAICKIT_STRESS_LOAD` | `3` | Concurrent mosaic jobs per round. |
/// | `MOSAICKIT_STRESS_STALL` | `30` | Seconds without progress that count as a stall. |
/// | `MOSAICKIT_STRESS_LEAVE_BACKGROUND` | unset | If set, leave background scheduling first. |
/// | `MOSAICKIT_PREVIEW_COMBO_RUN` | unset | `1` enables `PreviewCombinationTests`. |
/// | `MOSAICKIT_PREVIEW_RECURSIVE` | unset | `1` scans `MOSAICKIT_LOCALFOLDER` recursively in `PreviewCoordinatorTests`. |
/// | `MOSAICKIT_COMBO_MAX_CONCURRENT` | `1` | Concurrent generations in `CombinationTests`. |
///
/// On iOS, `xcodebuild` forwards only variables with the `TEST_RUNNER_` prefix.
enum TestEnvironment {

    // MARK: - Raw access

    static var all: [String: String] { ProcessInfo.processInfo.environment }

    /// A non-empty value, or `nil`.
    static func string(_ key: String) -> String? {
        guard let value = all[key], !value.isEmpty else { return nil }
        return value
    }

    static func flag(_ key: String) -> Bool { all[key] == "1" }

    static func int(_ key: String) -> Int? { string(key).flatMap { Int($0) } }

    static func double(_ key: String) -> Double? { string(key).flatMap { Double($0) } }

    private static func existingURL(_ key: String, directory: Bool) -> URL? {
        guard let path = string(key) else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue == directory else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: directory)
    }

    // MARK: - Files and folders

    static let localVideoKeys = (1...4).map { "MOSAICKIT_LOCALVIDEO\($0)" }

    /// `MOSAICKIT_LOCALVIDEO<n>` (1-based), when set and pointing at an existing file.
    static func localVideo(_ index: Int) -> URL? {
        guard (1...localVideoKeys.count).contains(index) else { return nil }
        return existingURL(localVideoKeys[index - 1], directory: false)
    }

    /// Every set `MOSAICKIT_LOCALVIDEO<n>` that exists, in order.
    static var localVideos: [URL] { (1...localVideoKeys.count).compactMap(localVideo) }

    /// `MOSAICKIT_LOCALFOLDER`, when set and pointing at an existing folder.
    static var localFolder: URL? { existingURL("MOSAICKIT_LOCALFOLDER", directory: true) }

    /// `MOSAICKIT_LOCALPLAYLIST`, when set and pointing at an existing file.
    static var localPlaylist: URL? { existingURL("MOSAICKIT_LOCALPLAYLIST", directory: false) }

    /// `MOSAICKIT_FFMPEG_PATH` if executable, else the first Homebrew / system `ffmpeg`.
    static var ffmpegPath: String? {
        let fm = FileManager.default
        if let path = string("MOSAICKIT_FFMPEG_PATH"), fm.isExecutableFile(atPath: path) { return path }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Outputs

    /// `MOSAICKIT_OUTPUTFOLDER` (created on demand), else a fresh temporary directory named
    /// `MosaicKitTests-<name>`. Not deleted: callers decide.
    static func outputFolder(named name: String) throws -> URL {
        let base = string("MOSAICKIT_OUTPUTFOLDER").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitTests-\(UUID().uuidString)", isDirectory: true)
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Run selection

    static var isCIMode: Bool { all["MOSAICKIT_SUITE_MODE"] == "none" }
    static var skipAnimated: Bool { all["MOSAICKIT_SKIP_ANIMATED"] == "1" }
}
