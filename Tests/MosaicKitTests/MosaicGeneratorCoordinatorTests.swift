import Foundation
import Testing
@testable import MosaicKit

struct MosaicGeneratorCoordinatorTests {
    private static let defaultMediaFolderPath = "/Volumes/volname/test/"
    private static let folderPathEnvKey = "MOSAICKIT_TEST_VIDEOS_DIR"
    private static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]

    @Test("Coordinator single test using media from /Volumes/volname/test/")
    func coordinatorSingleVideoFromFolder() async throws {
        guard currentMode() == .single else { return }

        try await withAccessibleMediaFolder { folderURL in
            let videoURLs = try discoverVideoURLs(in: folderURL)
            #expect(!videoURLs.isEmpty)
            guard let firstVideoURL = videoURLs.first else {
                throw MediaAccessError.noVideosFound(folderURL.path)
            }

            let video = try await VideoInput(from: firstVideoURL)
            let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
            let config = makeTestConfiguration(outputDirectory: folderURL)
            let progressStore = ProgressStore()

            let result = try await coordinator.generateMosaic(for: video, config: config) { progress in
                progressStore.append(progress)
            }

            #expect(result.isSuccess)
            if let outputURL = result.outputURL {
                #expect(outputURL.path.hasPrefix(folderURL.path))
                #expect(FileManager.default.fileExists(atPath: outputURL.path))
            }

            let statuses = progressStore.statuses(for: video.id)
            #expect(statuses.contains(.queued))
            #expect(statuses.contains(.inProgress))
            #expect(statuses.contains(.completed))
        }
    }

    @Test("Coordinator batch test using all videos in /Volumes/volname/test/")
    func coordinatorBatchFromFolder() async throws {
        guard currentMode() == .folder else { return }

        try await withAccessibleMediaFolder { folderURL in
            let videoURLs = try discoverVideoURLs(in: folderURL)
            #expect(!videoURLs.isEmpty)
            guard !videoURLs.isEmpty else {
                throw MediaAccessError.noVideosFound(folderURL.path)
            }

            var videos: [VideoInput] = []
            for url in videoURLs {
                if let input = try? await VideoInput(from: url) {
                    videos.append(input)
                }
            }

            #expect(!videos.isEmpty)
            guard !videos.isEmpty else {
                throw MediaAccessError.noReadableVideos(folderURL.path)
            }

            let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 2)
            let config = makeTestConfiguration(outputDirectory: folderURL)
            let progressStore = ProgressStore()

            let results = try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { progress in
                progressStore.append(progress)
            }

            #expect(results.count == videos.count)

            let successfulResults = results.filter(\.isSuccess)
            #expect(!successfulResults.isEmpty)

            for result in successfulResults {
                if let outputURL = result.outputURL {
                    #expect(outputURL.path.hasPrefix(folderURL.path))
                    #expect(FileManager.default.fileExists(atPath: outputURL.path))
                }
            }

            for video in videos {
                let statuses = progressStore.statuses(for: video.id)
                #expect(statuses.contains(.queued))
                #expect(statuses.contains(.inProgress))
            }
        }
    }

    @Test("Coordinator generates mosaic from embedded test video")
    func coordinatorSingleVideoFromEmbeddedAsset() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        let config = makeTestConfiguration(outputDirectory: outputDir)

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        if let outputURL = result.outputURL {
            #expect(FileManager.default.fileExists(atPath: outputURL.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let size = attrs[FileAttributeKey.size] as? Int ?? 0
            #expect(size > 0)
        }
    }

    private var embeddedVideoURL: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "test_video", withExtension: "mp4") else {
                throw MediaAccessError.noVideosFound("embedded asset test_video.mp4 not found in bundle")
            }
            return url
        }
    }

    private func withAccessibleMediaFolder<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let folderURL = mediaFolderURL()
        let didStartSecurityScope = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            throw MediaAccessError.folderMissing(folderURL.path)
        }

        _ = try discoverVideoURLs(in: folderURL)
        return try await operation(folderURL)
    }

    private func mediaFolderURL() -> URL {
        let path = ProcessInfo.processInfo.environment[Self.folderPathEnvKey] ?? Self.defaultMediaFolderPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func discoverVideoURLs(in folderURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                Issue.record("Directory scan error at \(url.path): \(error.localizedDescription)")
                return true
            }
        ) else {
            throw MediaAccessError.scanFailed(folderURL.path)
        }

        var foundURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                continue
            }

            let didStartFileScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didStartFileScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            if FileManager.default.isReadableFile(atPath: fileURL.path) {
                foundURLs.append(fileURL)
            }
        }

        return foundURLs.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func makeTestConfiguration(outputDirectory: URL) -> MosaicConfiguration {
        MosaicConfiguration(
            width: 1200,
            density: .xxl,
            format: .png,
            layout: LayoutConfiguration(
                aspectRatio: .widescreen,
                spacing: 6,
                layoutType: .classic,
                visual: VisualSettings(
                    addBorder: true,
                    borderColor: .gray,
                    borderWidth: 1,
                    addShadow: true,
                    shadowSettings: .default
                )
            ),
            includeMetadata: false,
            useAccurateTimestamps: false,
            compressionQuality: 0.5,
            outputdirectory: outputDirectory,
            fullPathInName: false,
            useMovieColorsForBg: false,
            backgroundColor: .defaultGray
        )
    }

    private func currentMode() -> SuiteMode {
        let rawValue = ProcessInfo.processInfo.environment["MOSAICKIT_SUITE_MODE"] ?? "none"
        return SuiteMode(rawValue: rawValue.lowercased()) ?? .single
    }
}

private enum SuiteMode: String {
    case single
    case folder
    case none
}

private enum MediaAccessError: Error, CustomStringConvertible {
    case folderMissing(String)
    case scanFailed(String)
    case noVideosFound(String)
    case noReadableVideos(String)

    var description: String {
        switch self {
        case .folderMissing(let path):
            return "Media folder not found: \(path). Set MOSAICKIT_TEST_VIDEOS_DIR if needed."
        case .scanFailed(let path):
            return "Unable to scan media folder: \(path). Check sandbox/filesystem permissions."
        case .noVideosFound(let path):
            return "No supported videos found in: \(path)."
        case .noReadableVideos(let path):
            return "Videos found but not readable in: \(path). Check permissions."
        }
    }
}

private final class ProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var statusesByVideoID: [UUID: [MosaicGenerationStatus]] = [:]

    func append(_ progress: MosaicGenerationProgress) {
        lock.lock()
        statusesByVideoID[progress.video.id, default: []].append(progress.status)
        lock.unlock()
    }

    func statuses(for videoID: UUID) -> [MosaicGenerationStatus] {
        lock.lock()
        defer { lock.unlock() }
        return statusesByVideoID[videoID] ?? []
    }
}
