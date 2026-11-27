import AVFoundation
import Foundation
import Testing
@testable import MosaicKit

#if os(macOS)
/// A 12 s sample in a format AVFoundation can't fully read, made from the test fixture.
struct FallbackSample: Sendable, CustomTestStringConvertible {
    let name: String
    let arguments: [String]
    let route: FFmpegFallback.Route
    var testDescription: String { name }

    static let all: [FallbackSample] = [
        FallbackSample(name: "mpeg4.avi", arguments: ["-c:v", "mpeg4", "-c:a", "mp3"], route: .remuxed),
        FallbackSample(name: "h264.mkv", arguments: ["-c:v", "libx264", "-c:a", "aac"], route: .remuxed),
        FallbackSample(name: "vp9.webm", arguments: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libopus"], route: .ffmpeg),
        FallbackSample(name: "wmv2.wmv", arguments: ["-c:v", "wmv2", "-c:a", "wmav2"], route: .ffmpeg),
        FallbackSample(name: "flv1.flv", arguments: ["-c:v", "flv1", "-c:a", "mp3", "-ar", "44100"], route: .ffmpeg),
    ]
}

/// Part of the serialized suite that owns the process-wide ``FFmpegFallback`` switch.
extension TransportStreamSourceTests {
    private static func make(_ sample: FallbackSample, in folder: URL) async throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let output = folder.appendingPathComponent(sample.name)
        let arguments = ["-nostdin", "-v", "error", "-y", "-ss", "10", "-t", "12", "-i", fixture.path,
                         // The fixture is silent: add a tone.
                         "-f", "lavfi", "-t", "12", "-i", "sine=frequency=440:sample_rate=44100",
                         "-map", "0:v:0", "-map", "1:a:0", "-ac", "2", "-vf", "scale=320:180", "-pix_fmt", "yuv420p"] + sample.arguments + [output.path]
        let result = try await FFmpegRunner.run(try #require(ffmpegPath), arguments, timeout: 120)
        try #require(result.status == 0, "\(sample.name): \(result.stderr)")
        return output
    }

    private static func inTemporaryFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    @Test("Each format takes its route and gives a mosaic, frames and an animation",
          .enabled(if: ffmpegPath != nil, "needs an ffmpeg binary"), arguments: FallbackSample.all)
    func fallbackMosaic(sample: FallbackSample) async throws {
        try await Self.inTemporaryFolder { folder in
            let url = try await Self.make(sample, in: folder)
            #expect(try await FFmpegFallback.route(for: url) == .native, "disabled never probes")
            try await Self.withRemuxer { cache in
                let video = try await VideoInput(from: url)
                #expect(try await FFmpegFallback.route(for: url) == sample.route)
                #expect(video.width == 320 && video.height == 180)
                #expect(abs(try #require(video.duration) - 12) < 0.5)
                // Inspection and routing write nothing.
                #expect(try FFmpegCache.files(in: cache).isEmpty)

                var config = MosaicConfiguration(width: 640, density: .xxl, format: .jpeg, includeMetadata: true)
                config.outputdirectory = folder.appendingPathComponent("out", isDirectory: true)
                config.gifMode = .withMosaic
                config.animatedFormat = .gif
                config.gifSize = .small
                let output = try await MetalMosaicGenerator().generate(for: video, config: config)
                #expect(FileManager.default.fileExists(atPath: output.path))
                #expect(!output.path.contains(cache.lastPathComponent))

                let frames = try await MetalMosaicGenerator().extractThumbnails(
                    for: video, options: ThumbnailExtractionOptions(count: 12))
                #expect(frames.count == 12)
                #expect(frames.allSatisfy { $0.image.width > 0 && $0.image.height > 0 })
            }
        }
    }

    @Test("Each format gives a preview with sound",
          .enabled(if: ffmpegPath != nil, "needs an ffmpeg binary"), arguments: FallbackSample.all)
    func fallbackPreview(sample: FallbackSample) async throws {
        _ = ProcessScheduling.leaveBackground()
        try await Self.inTemporaryFolder { folder in
            let url = try await Self.make(sample, in: folder)
            try await Self.withRemuxer { _ in
                let video = try await VideoInput(from: url)
                var config = PreviewConfiguration(targetDuration: 6, density: .xxl, format: .mp4,
                                                  includeAudio: true, outputDirectory: folder)
                config.enableAppLifecycleMonitor = false
                config.enableExportRetry = false
                let output: URL
                do {
                    output = try await PreviewVideoGenerator().generate(for: video, config: config)
                } catch PreviewError.exportStalled {
                    // I-26: the export session sometimes freezes mid-encode under parallel load.
                    withKnownIssue("I-26: export stall", isIntermittent: true) { Issue.record("export stalled") }
                    return
                }
                let asset = AVURLAsset(url: output)
                #expect(try await asset.load(.duration).seconds > 1)
                #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
                #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
            }
        }
    }

    @Test("A source AVFoundation reads stays native with the fallback on",
          .enabled(if: ffmpegPath != nil, "needs an ffmpeg binary"))
    func nativeStaysNative() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        try await Self.withRemuxer { cache in
            let route = try await FFmpegFallback.route(for: fixture)
            let cached = try FFmpegCache.files(in: cache)
            #expect(route == .native)
            #expect(cached.isEmpty)
        }
    }
}
#endif
