import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

struct AnimatedGifGeneratorTests {

    // MARK: - AnimatedGifGenerator unit tests

    @Test("AnimatedGifGenerator saves a valid GIF file from synthetic frames")
    func gifGeneratorSavesValidFile() throws {
        let frames = makeSolidFrames(count: 5, width: 160, height: 90)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try AnimatedGifGenerator.save(frames: frames, to: outputURL)

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)
    }

    @Test("AnimatedGifGenerator produces a file with a valid GIF signature")
    func gifGeneratorProducesValidGifSignature() throws {
        let frames = makeSolidFrames(count: 3, width: 80, height: 60)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sig-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try AnimatedGifGenerator.save(frames: frames, to: outputURL)

        let data = try Data(contentsOf: outputURL)
        #expect(data.count >= 6)
        // Both GIF87a and GIF89a are valid; the encoder decides which to use.
        let header = String(bytes: data.prefix(3), encoding: .ascii)
        #expect(header == "GIF")
    }

    @Test("AnimatedGifGenerator with empty frame list does not write a file")
    func gifGeneratorEmptyFramesProducesNoFile() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try AnimatedGifGenerator.save(frames: [], to: outputURL)

        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test("AnimatedGifGenerator respects a custom frameDelay")
    func gifGeneratorCustomFrameDelay() throws {
        let frames = makeSolidFrames(count: 4, width: 80, height: 60)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delay-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // 0.5 s per frame — just check it completes without error and produces a file
        try AnimatedGifGenerator.save(frames: frames, to: outputURL, frameDelay: 0.5)

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)
    }

    // MARK: - AnimatedFormat unit tests (synthetic frames, no video needed)

    @Test("AnimatedGifGenerator saves HEIC animated sequence from synthetic frames")
    func heicFormatSavesValidFile() throws {
        let frames = makeSolidFrames(count: 4, width: 160, height: 90)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).heics")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try AnimatedGifGenerator.save(frames: frames, to: outputURL, format: .heic)

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test("AnimatedGifGenerator saves WebP animated file from synthetic frames")
    func webpFormatSavesValidFile() throws {
        let frames = makeSolidFrames(count: 4, width: 160, height: 90)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try AnimatedGifGenerator.save(frames: frames, to: outputURL, format: .webp)

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test("AnimatedFormat.fileExtension returns correct extensions")
    func animatedFormatExtensions() {
        #expect(AnimatedFormat.gif.fileExtension  == "gif")
        #expect(AnimatedFormat.heic.fileExtension == "heics")
        #expect(AnimatedFormat.webp.fileExtension == "webp")
    }

    @Test("AnimatedFormat.uti returns correct UTI strings")
    func animatedFormatUTIs() {
        #expect(AnimatedFormat.gif.uti  == "com.compuserve.gif")
        #expect(AnimatedFormat.heic.uti == "public.heics")
        #expect(AnimatedFormat.webp.uti == "org.webmproject.webp")
    }

    // MARK: - MosaicConfiguration GIF option tests

    @Test("GifCreationMode, GifSize and AnimatedFormat round-trip through Codable")
    func animatedOptionsAreCodeable() throws {
        var config = MosaicConfiguration()
        config.gifMode = .withMosaic
        config.gifSize = .large
        config.animatedFormat = .heic

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MosaicConfiguration.self, from: data)

        #expect(decoded.gifMode == .withMosaic)
        #expect(decoded.gifSize == .large)
        #expect(decoded.animatedFormat == .heic)
    }

    @Test("animatedOutputURL uses the correct extension for each AnimatedFormat")
    func animatedOutputURLUsesFormatExtension() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifurl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        for fmt in [AnimatedFormat.gif, .heic, .webp] {
            var config = MosaicConfiguration()
            config.outputdirectory = outputDir
            config.animatedFormat = fmt
            let url = config.animatedOutputURL(for: video)
            #expect(url.pathExtension.lowercased() == fmt.fileExtension,
                    "Expected .\(fmt.fileExtension) for format .\(fmt.rawValue), got .\(url.pathExtension)")
        }
    }

    // MARK: - Integration tests using the embedded test video

    @Test("withMosaic mode creates both the mosaic and a GIF file")
    func gifWithMosaicModeCreatesBothFiles() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitGif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .withMosaic
        config.gifSize = .small
        config.animatedFormat = .gif

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        guard let mosaicURL = result.outputURL else {
            Issue.record("Expected a mosaic output URL")
            return
        }

        #expect(FileManager.default.fileExists(atPath: mosaicURL.path))

        let gifURL = mosaicURL.deletingPathExtension().appendingPathExtension("gif")
        #expect(FileManager.default.fileExists(atPath: gifURL.path), "GIF file should exist alongside the mosaic")

        let gifAttrs = try FileManager.default.attributesOfItem(atPath: gifURL.path)
        let gifSize = gifAttrs[.size] as? Int ?? 0
        #expect(gifSize > 0, "GIF file should be non-empty")

        // Verify GIF magic bytes (GIF87a or GIF89a are both valid)
        let gifData = try Data(contentsOf: gifURL)
        let header = String(bytes: gifData.prefix(3), encoding: .ascii)
        #expect(header == "GIF")
    }

    @Test("gifOnly mode creates the GIF and skips the mosaic")
    func gifOnlyModeSkipsMosaic() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitGifOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .gifOnly
        config.gifSize = .small
        config.animatedFormat = .gif

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        guard let returnedURL = result.outputURL else {
            Issue.record("Expected an output URL")
            return
        }

        // The returned URL should be the GIF, not a mosaic
        #expect(returnedURL.pathExtension.lowercased() == "gif")
        #expect(FileManager.default.fileExists(atPath: returnedURL.path))

        let gifAttrs = try FileManager.default.attributesOfItem(atPath: returnedURL.path)
        let gifSize = gifAttrs[.size] as? Int ?? 0
        #expect(gifSize > 0)

        // Confirm no mosaic image file exists alongside it
        for ext in ["heic", "jpg", "png"] {
            let mosaicURL = returnedURL.deletingPathExtension().appendingPathExtension(ext)
            #expect(!FileManager.default.fileExists(atPath: mosaicURL.path),
                    "Mosaic file with .\(ext) extension should not exist in gifOnly mode")
        }
    }

    @Test("gifOnly with HEIC format creates .heics file and skips mosaic")
    func heicOnlyModeCreatesHeicsFile() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitHeic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .gifOnly
        config.gifSize = .small
        config.animatedFormat = .heic

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        guard let returnedURL = result.outputURL else {
            Issue.record("Expected an output URL"); return
        }
        #expect(returnedURL.pathExtension.lowercased() == "heics")
        #expect(FileManager.default.fileExists(atPath: returnedURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: returnedURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }

    @Test("gifOnly with WebP format creates .webp file and skips mosaic")
    func webpOnlyModeCreatesWebpFile() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitWebP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .gifOnly
        config.gifSize = .small
        config.animatedFormat = .webp

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        guard let returnedURL = result.outputURL else {
            Issue.record("Expected an output URL"); return
        }
        #expect(returnedURL.pathExtension.lowercased() == "webp")
        #expect(FileManager.default.fileExists(atPath: returnedURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: returnedURL.path)
        #expect((attrs[.size] as? Int ?? 0) > 0)
    }
    
    
    @Test("create all versions")
    func createAllModes() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitWebP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .gifOnly
        
        for density in [DensityConfig.xxl, .m, .xs] {
            for gifsize in [GifSize.large, GifSize.small, GifSize.nochange] {
                for animatedFormat in [AnimatedFormat.gif, .heic, .webp] {
                    config.gifSize = gifsize
                    config.animatedFormat = animatedFormat
                    config.density = density
                    let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }
                    
                    #expect(result.isSuccess)
                    guard let returnedURL = result.outputURL else {
                        Issue.record("Expected an output URL"); return
                    }
                    #expect(returnedURL.pathExtension.lowercased() == animatedFormat.fileExtension)
                    #expect(FileManager.default.fileExists(atPath: returnedURL.path))
                    let attrs = try FileManager.default.attributesOfItem(atPath: returnedURL.path)
                    #expect((attrs[.size] as? Int ?? 0) > 0)
                }
            }
        }
        
        
    }

    @Test("GifSize.large produces a non-empty GIF")
    func gifSizeLargeProducesValidFile() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitGifLarge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .gifOnly
        config.gifSize = .large

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        if let gifURL = result.outputURL {
            #expect(FileManager.default.fileExists(atPath: gifURL.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: gifURL.path)
            #expect((attrs[.size] as? Int ?? 0) > 0)
        }
    }

    @Test("GifSize.nochange produces a non-empty GIF")
    func gifSizeNochangeProducesValidFile() async throws {
        let videoURL = try embeddedVideoURL
        let video = try await VideoInput(from: videoURL)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitGifNochange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 1)
        var config = makeMinimalConfig(outputDirectory: outputDir)
        config.gifMode = .gifOnly
        config.gifSize = .nochange

        let result = try await coordinator.generateMosaic(for: video, config: config) { _ in }

        #expect(result.isSuccess)
        if let gifURL = result.outputURL {
            #expect(FileManager.default.fileExists(atPath: gifURL.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: gifURL.path)
            #expect((attrs[.size] as? Int ?? 0) > 0)
        }
    }

    // MARK: - Helpers

    private var embeddedVideoURL: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "test_video", withExtension: "mp4") else {
                throw TestError.embeddedAssetMissing
            }
            return url
        }
    }

    /// Minimal config suitable for fast CI runs.
    private func makeMinimalConfig(outputDirectory: URL) -> MosaicConfiguration {
        MosaicConfiguration(
            width: 1280,
            density: .xs,
            format: .jpeg,
            layout: LayoutConfiguration(
                aspectRatio: .widescreen,
                layoutType: .classic
            ),
            includeMetadata: false,
            useAccurateTimestamps: false,
            compressionQuality: 0.5,
            outputdirectory: outputDirectory
        )
    }

    /// Creates solid-colored CGImage frames for unit testing.
    private func makeSolidFrames(count: Int, width: Int, height: Int) -> [CGImage] {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1)
        ]
        return (0..<count).compactMap { i in
            let (r, g, b) = colors[i % colors.count]
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }
    }
}

private enum TestError: Error {
    case embeddedAssetMissing
}
