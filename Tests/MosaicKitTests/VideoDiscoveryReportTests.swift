import Foundation
import Testing
@testable import MosaicKit

/// Discovery that keeps going past files it can't inspect (implementation plan F-8c, knowledge base I-17).
struct VideoDiscoveryReportTests {

    /// A folder with one real video (the fixture) and two files that look like videos but aren't.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("a-good.mp4"))
        try Data().write(to: folder.appendingPathComponent("b-empty.mkv"))
        try Data("not a video".utf8).write(to: folder.appendingPathComponent("c-garbage.mp4"))
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        return folder
    }

    @Test("The report keeps the good video and lists each bad file with its error, in filename order")
    func reportsFailures() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let report = try await discoverVideosReportingFailures(in: folder, metadataConcurrency: 2)

        #expect(report.videos.map(\.url.lastPathComponent) == ["a-good.mp4"])
        #expect(report.videos.first?.duration != nil)
        #expect(report.failures.map(\.url.lastPathComponent) == ["b-empty.mkv", "c-garbage.mp4"])
        for failure in report.failures {
            #expect(!(failure.error is CancellationError), "\(failure.url.lastPathComponent)")
            #expect(!failure.error.localizedDescription.isEmpty)
        }
    }

    @Test("discoverVideos still throws on the first bad file")
    func strictDiscoveryStillThrows() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: (any Error).self) { try await discoverVideos(in: folder, metadataConcurrency: 1) }
    }

    @Test("A folder of good videos reports no failures; an empty folder reports nothing")
    func cleanAndEmptyFolders() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b-empty.mkv"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("c-garbage.mp4"))
        let clean = try await discoverVideosReportingFailures(in: folder)
        #expect(clean.videos.count == 1 && clean.failures.isEmpty)
        #expect(try await discoverVideos(in: folder).count == 1)

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let none = try await discoverVideosReportingFailures(in: empty)
        #expect(none.videos.isEmpty && none.failures.isEmpty)
    }

    @Test("Bad concurrency and cancellation still throw; they are not reported as per-file failures")
    func argumentAndCancellationErrors() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: (any Error).self) { try await discoverVideosReportingFailures(in: folder, metadataConcurrency: 0) }
        await #expect(throws: (any Error).self) { try await discoverVideosReportingFailures(in: folder, metadataConcurrency: 65) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await discoverVideosReportingFailures(in: folder)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let notADirectory = folder.appendingPathComponent("a-good.mp4")
        await #expect(throws: (any Error).self) { try await discoverVideosReportingFailures(in: notADirectory) }
    }
}
