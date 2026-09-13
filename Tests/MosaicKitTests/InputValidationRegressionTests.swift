import CoreGraphics
import Foundation
import Testing
import MosaicKitWebP
@testable import MosaicKit

@Suite("Input and configuration reliability")
struct InputValidationRegressionTests {
    @Test("Canonical metadata cloning performs no I/O and preserves all fields")
    func canonicalClone() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let source = VideoSource(url: missing, title: "title", postID: "post")
        #expect(source.url == missing)
        let metadata = VideoMetadata(codec: "custom", bitrate: 42, custom: ["origin": "test"])
        let input = VideoInput(canonicalID: UUID(), url: missing, title: "title", duration: 12,
                               width: 1920, height: 1080, frameRate: 29.97, fileSize: 123,
                               metadata: metadata, postID: "post")
        let nextID = UUID()
        let clone = input.withID(nextID)
        #expect(clone.id == nextID)
        #expect(clone.withID(input.id) == input)
        try clone.validate()
    }

    @Test("Inspection accepts ordinary files and preserves supplied custom metadata")
    func inspectOrdinaryFile() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let supplied = VideoInput(canonicalID: UUID(), url: url, title: "Supplied title", duration: 42,
                                  metadata: VideoMetadata(codec: "retained", custom: ["key": "value"]))
        let input = try await VideoSource(url: url).inspect(preserving: supplied)
        #expect(input.id == supplied.id)
        #expect(input.title == supplied.title)
        #expect(input.duration == 42)
        #expect(input.metadata.codec == "retained")
        #expect(input.metadata.custom == ["key": "value"])
        #expect((input.width ?? 0) > 0)
        let legacy = try await VideoInput(from: url)
        #expect((legacy.duration ?? 0) > 0)
    }

    @Test("Inspection reports invalid sources and caller cancellation")
    func inspectionErrors() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        await #expect(throws: (any Error).self) { try await VideoSource(url: missing).inspect() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoSource(url: missing).inspect()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test("Discovery is throwing, filters files and observes cancellation")
    func discovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("b.mp4"))
        try Data().write(to: folder.appendingPathComponent("a.mov"))
        try Data().write(to: folder.appendingPathComponent("ignored.txt"))
        let sources = try await discoverVideoSources(in: folder)
        #expect(sources.map(\.url.lastPathComponent) == ["a.mov", "b.mp4"])
        await #expect(throws: (any Error).self) { try await discoverVideos(in: folder, metadataConcurrency: 1) }
        await #expect(throws: (any Error).self) { try await discoverVideos(in: folder, metadataConcurrency: -1) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await discoverVideoSources(in: folder)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test("Custom densities survive new encoding and legacy factor-only decoding")
    func densityRoundTrip() throws {
        let custom = DensityConfig(name: "My density", factor: 1.25, extractsMultiplier: 2.5, thumbnailCountDescription: "retained")
        #expect(try JSONDecoder().decode(DensityConfig.self, from: JSONEncoder().encode(custom)) == custom)
        #expect(try JSONDecoder().decode(DensityConfig.self, from: Data(#"{"factor":1}"#.utf8)) == .m)
        #expect(try JSONDecoder().decode(DensityConfig.self, from: Data(#"{"factor":1.25}"#.utf8)).factor == 1.25)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DensityConfig.self, from: Data(#"{"factor":-1}"#.utf8)) }
    }

    @Test("Invalid numeric values fail validation and never trap legacy helpers")
    func invalidNumbers() throws {
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            var preview = PreviewConfiguration()
            preview.targetDuration = invalid
            #expect(throws: (any Error).self) { try preview.validate() }
            #expect(preview.extractCount(forVideoDuration: invalid) == 1)
            #expect(PreviewConfiguration.extractCountExt(forVideoDuration: invalid, density: "M", targetDuration: 30) == 1)
            let parameters = preview.calculateExtractParameters(forVideoDuration: invalid)
            #expect(parameters.extractDuration.isFinite)
            #expect(parameters.playbackSpeed.isFinite)
            _ = PreviewConfiguration.durationLabel(for: invalid)
            var mosaic = MosaicConfiguration()
            mosaic.density = DensityConfig(name: "bad", factor: invalid, extractsMultiplier: 1, thumbnailCountDescription: "bad")
            #expect(throws: (any Error).self) { try mosaic.validate() }
        }
        var mosaic = MosaicConfiguration()
        mosaic.width = Int.max
        #expect(throws: (any Error).self) { try mosaic.validate() }
        mosaic.width = 100
        mosaic.gifFps = .nan
        #expect(throws: (any Error).self) { try mosaic.validate() }
        var preview = PreviewConfiguration()
        preview.compressionQuality = .nan
        #expect(throws: (any Error).self) { try preview.validate() }
        preview.compressionQuality = 0.5
        preview.exportMode = .ffmpeg
        preview.showTimestampOverlay = true
        #expect(throws: (any Error).self) { try preview.validate() }
    }

    @Test("HEVC 1080p reports its actual preset cap")
    func presetCap() {
        #expect(nativeExportPreset.maxResolution(forPresetName: "AVAssetExportPresetHEVC1920x1080") == CGSize(width: 1920, height: 1080))
    }
    @Test("WebP validates unrepresentable timing before invoking the codec")
    func webPInputValidation() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let encoder = DefaultMosaicKitWebPEncoder()
        #expect(throws: (any Error).self) { try encoder.encodeStillWebP(image, quality: .nan) }
        for delay in [Double.nan, .infinity, 0, -1, Double.greatestFiniteMagnitude] {
            #expect(throws: (any Error).self) { try encoder.encodeAnimatedWebP(frames: [image], frameDelay: delay) }
        }
        #expect(throws: (any Error).self) { try encoder.encodeAnimatedWebP(frames: [], frameDelay: 0.1) }
    }

}
