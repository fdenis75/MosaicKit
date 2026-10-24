import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import MosaicKit

/// Public thumbnail extraction: `MetalMosaicGenerator.extractThumbnails(for:options:)`,
/// `extractThumbnailImages(for:options:)` and `exportThumbnails(for:options:to:)`.
struct ThumbnailExtractionTests {

    private func fixture(_ name: String) async throws -> VideoInput {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mp4"),
                               "Missing test fixture \(name).mp4")
        return try await VideoInput(from: url)
    }

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailExtractionTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Extracts the requested count, in temporal order, within 5…95 % and the size box")
    func extractsUniformFrames() async throws {
        let video = try await fixture("test_video")
        let duration = try #require(video.duration)
        let box = CGSize(width: 320, height: 320)
        let thumbnails = try await MetalMosaicGenerator().extractThumbnails(
            for: video, options: ThumbnailExtractionOptions(count: 6, maximumSize: box)
        )
        #expect(thumbnails.map(\.index) == Array(0..<6))
        let times = thumbnails.map(\.time)
        #expect(times == times.sorted())
        // Non-accurate decoding may pick a frame up to 1 s from the requested time.
        #expect(times.allSatisfy { $0 >= duration * 0.05 - 1 && $0 <= duration * 0.95 + 1 })
        for thumbnail in thumbnails {
            #expect(CGFloat(thumbnail.image.width) <= box.width && CGFloat(thumbnail.image.height) <= box.height)
            #expect(thumbnail.image.width > 0 && thumbnail.image.height > 0)
        }
    }

    @Test("extractThumbnailImages returns just the images")
    func extractsImages() async throws {
        let video = try await fixture("test_video")
        let images = try await MetalMosaicGenerator().extractThumbnailImages(
            for: video, options: ThumbnailExtractionOptions(count: 3, maximumSize: CGSize(width: 160, height: 160), sampling: .weighted)
        )
        #expect(images.count == 3)
    }

    @Test("Frames of a rotated source are upright")
    func rotatedSourceIsUpright() async throws {
        let video = try await fixture("rotated_portrait")
        let images = try await MetalMosaicGenerator().extractThumbnailImages(
            for: video, options: ThumbnailExtractionOptions(count: 2)
        )
        let image = try #require(images.first)
        #expect(image.height > image.width, "Frame is \(image.width)×\(image.height)")
    }

    @Test("Export to a new temporary directory writes decodable, numbered files")
    func exportsToTemporaryDirectory() async throws {
        let video = try await fixture("test_video")
        let export = try await MetalMosaicGenerator().exportThumbnails(
            for: video, options: ThumbnailExtractionOptions(count: 3, maximumSize: CGSize(width: 200, height: 200))
        )
        defer { try? FileManager.default.removeItem(at: export.directory) }
        #expect(export.directory.path.contains("MosaicKitThumbnails"))
        #expect(export.files.map { $0.url.lastPathComponent } == ["test_video_0001.jpg", "test_video_0002.jpg", "test_video_0003.jpg"])
        for file in export.files {
            #expect(file.url.deletingLastPathComponent().standardizedFileURL == export.directory.standardizedFileURL)
            let source = try #require(CGImageSourceCreateWithURL(file.url as CFURL, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        }
        // No staging files are left behind.
        let contents = try FileManager.default.contentsOfDirectory(atPath: export.directory.path)
        #expect(contents.sorted() == export.files.map { $0.url.lastPathComponent })
    }

    @Test("Export to a caller directory creates it and uses the chosen format")
    func exportsToCallerDirectory() async throws {
        let video = try await fixture("test_video")
        let directory = scratchDirectory().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let export = try await MetalMosaicGenerator().exportThumbnails(
            for: video,
            options: ThumbnailExtractionOptions(count: 2, maximumSize: CGSize(width: 120, height: 120), format: .png),
            to: directory
        )
        #expect(export.directory == directory)
        #expect(export.files.count == 2)
        #expect(export.files.allSatisfy { $0.url.pathExtension == "png" && FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("A cancelled extraction throws CancellationError")
    func cancelledExtractionThrows() async throws {
        let video = try await fixture("test_video")
        let generator = try MetalMosaicGenerator()
        let task = Task {
            try await generator.extractThumbnails(for: video, options: ThumbnailExtractionOptions(count: 50, accurate: true))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A cancelled export removes the directory it created")
    func cancelledExportCleansUp() async throws {
        let video = try await fixture("test_video")
        let generator = try MetalMosaicGenerator()
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try await generator.exportThumbnails(for: video, options: ThumbnailExtractionOptions(count: 50), to: directory)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("A cancelled export into a shared caller directory keeps other files")
    func cancelledExportKeepsOtherFiles() async throws {
        let video = try await fixture("test_video")
        let generator = try MetalMosaicGenerator()
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Another export's output in the same directory, under another video's name.
        let other = try await generator.exportThumbnails(
            for: video, options: ThumbnailExtractionOptions(count: 1, maximumSize: CGSize(width: 64, height: 64)), to: directory
        )
        let otherFile = try #require(other.files.first?.url)
        let renamed = directory.appendingPathComponent("other_0001.jpg")
        try FileManager.default.moveItem(at: otherFile, to: renamed)
        let task = Task {
            try await generator.exportThumbnails(for: video, options: ThumbnailExtractionOptions(count: 50), to: directory)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test("Invalid options are rejected before any decode", arguments: [
        ThumbnailExtractionOptions(count: 0),
        ThumbnailExtractionOptions(count: ThumbnailExtractionOptions.maximumCount + 1),
        ThumbnailExtractionOptions(maximumSize: CGSize(width: 0, height: 100)),
        ThumbnailExtractionOptions(maximumSize: CGSize(width: CGFloat.infinity, height: 100)),
        ThumbnailExtractionOptions(compressionQuality: 1.5),
    ])
    func rejectsInvalidOptions(options: ThumbnailExtractionOptions) {
        #expect(throws: MosaicError.self) { try options.validate() }
    }

    @Test("In-memory extraction ignores the file settings")
    func inMemoryIgnoresFileSettings() throws {
        try ThumbnailExtractionOptions(compressionQuality: 7).validateFrameSelection()
    }

    @Test("Options round-trip through Codable, and an empty payload decodes to the defaults")
    func optionsCodable() throws {
        let options = ThumbnailExtractionOptions(count: 12, maximumSize: CGSize(width: 640, height: 360),
                                                 sampling: .weighted, accurate: true, format: .heif, compressionQuality: 0.5)
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(ThumbnailExtractionOptions.self, from: data) == options)
        #expect(try JSONDecoder().decode(ThumbnailExtractionOptions.self, from: Data("{}".utf8)) == ThumbnailExtractionOptions())
    }
}
