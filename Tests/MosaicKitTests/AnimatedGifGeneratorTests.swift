import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import MosaicKit
import MosaicKitWebP

struct AnimatedGifGeneratorTests {

    init() {
        // .webp tests below need an encoder registered; MosaicKit itself no
        // longer links webp directly (see Sources/Processing/WebPSupport.swift).
        MosaicKitWebP.register()
    }

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

    @Test("AnimatedGifGenerator rejects an empty frame list without writing a file")
    func gifGeneratorEmptyFramesProducesNoFile() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        #expect(throws: MosaicError.self) {
            try AnimatedGifGenerator.save(frames: [], to: outputURL)
        }

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

    /// `MetalMosaicGenerator` passes `1 / gifFps` as the frame delay, so reading the
    /// delay back from every frame checks each format × fps combination in
    /// milliseconds, without extracting frames from a video.
    @Test("Animated formats store the requested per-frame delay",
          arguments: [AnimatedFormat.gif, .heic, .webp], [2.0, 5.0, 10.0, 25.0])
    func animatedFormatStoresFrameDelay(format: AnimatedFormat, fps: Double) throws {
        let frames = makeSolidFrames(count: 3, width: 64, height: 36)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delay-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let expectedDelay = 1.0 / fps
        try AnimatedGifGenerator.save(frames: frames, to: outputURL, format: format, frameDelay: expectedDelay)

        let source = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let frameCount = CGImageSourceGetCount(source)
        #expect(frameCount == frames.count)
        for index in 0..<frameCount {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let delay = try #require(storedFrameDelay(in: properties, format: format),
                                     "No delay stored for frame \(index) of .\(format.rawValue)")
            // GIF stores centiseconds and WebP milliseconds; every tested fps is exact in both.
            #expect(abs(delay - expectedDelay) < 0.005,
                    ".\(format.rawValue) at \(fps) fps: frame \(index) delay \(delay), expected \(expectedDelay)")
        }
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

        let gifURL = config.animatedOutputURL(for: video)
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

    /// Full density × size × format × fps matrix (108 end-to-end generations from the
    /// embedded video). It takes ~2.5 min on macOS and ~12 min on the iOS Simulator,
    /// where every animated HEIC encode also floods the log with `(Fig) signalled err`
    /// lines, while each dimension is already covered by a dedicated test. Skipped
    /// when `MOSAICKIT_SUITE_MODE=none` (CI); run it locally as an extended suite.
    @Test("create all versions",
          .enabled(if: ProcessInfo.processInfo.environment["MOSAICKIT_SUITE_MODE"] != "none",
                   "Extended matrix; skipped when MOSAICKIT_SUITE_MODE=none"))
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
                    for fps in [2.0, 5.0, 10.0, 25.0] {
                        config.gifSize = gifsize
                        config.animatedFormat = animatedFormat
                        config.density = density
                        config.gifFps = fps
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
                // Opaque frames: an alpha channel makes ImageIO log an
                // "opaque image with 'AlphaLast'" error on every write.
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }
    }

    /// Reads the frame delay ImageIO decodes for one frame, preferring the unclamped
    /// value (ImageIO may clamp short delays such as 25 fps in the plain key).
    private func storedFrameDelay(in properties: [String: Any], format: AnimatedFormat) -> Double? {
        let dictionaryKey: CFString
        let unclampedKey: CFString
        let delayKey: CFString
        switch format {
        case .gif:
            dictionaryKey = kCGImagePropertyGIFDictionary
            unclampedKey = kCGImagePropertyGIFUnclampedDelayTime
            delayKey = kCGImagePropertyGIFDelayTime
        case .heic:
            dictionaryKey = kCGImagePropertyHEICSDictionary
            unclampedKey = kCGImagePropertyHEICSUnclampedDelayTime
            delayKey = kCGImagePropertyHEICSDelayTime
        case .webp:
            dictionaryKey = kCGImagePropertyWebPDictionary
            unclampedKey = kCGImagePropertyWebPUnclampedDelayTime
            delayKey = kCGImagePropertyWebPDelayTime
        }
        guard let dictionary = properties[dictionaryKey as String] as? [String: Any] else { return nil }
        return (dictionary[unclampedKey as String] as? Double) ?? (dictionary[delayKey as String] as? Double)
    }
}

private enum TestError: Error {
    case embeddedAssetMissing
}
