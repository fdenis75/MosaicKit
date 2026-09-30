import Foundation
import AVFoundation
import Testing
@testable import MosaicKit

/// Regression tests for the ffmpeg argument template (I-2 scale filter, I-3 frame rate and
/// pixel format).
@Suite("FFmpeg arguments (I-2, I-3)")
struct FFmpegArgumentsTests {

    private let input = URL(fileURLWithPath: "/tmp/in.mov")
    private let output = URL(fileURLWithPath: "/tmp/out.mp4")

    private func arguments(_ codec: FFmpegEncodingOptions.VideoCodec,
                           maxResolution: ExportMaxResolution? = ._1080p) -> [String] {
        FFmpegEncodingOptions(videoCodec: codec, maxResolution: maxResolution)
            .buildArguments(inputURL: input, outputURL: output, includeAudio: false)
    }

    /// The value that follows `flag` in `args`, if any.
    private func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @Test("Scale filter preserves aspect ratio and swaps the bound for portrait")
    func scaleFilter() {
        #expect(ExportMaxResolution._1080p.scaleFilter ==
            "scale=w='if(gt(ih,iw),min(1080,iw),min(1920,iw))'"
            + ":h='if(gt(ih,iw),min(1920,ih),min(1080,ih))'"
            + ":force_original_aspect_ratio=decrease:force_divisible_by=2")
    }

    @Test("Every re-encoding codec gets the scale filter; copy does not",
          arguments: FFmpegEncodingOptions.VideoCodec.allCases)
    func scaleFilterPerCodec(codec: FFmpegEncodingOptions.VideoCodec) {
        let args = arguments(codec, maxResolution: ._720p)
        if codec == .copy {
            #expect(!args.contains("-vf"))
        } else {
            #expect(value(of: "-vf", in: args) == ExportMaxResolution._720p.scaleFilter)
        }
        #expect(!arguments(codec, maxResolution: nil).contains("-vf"))
    }

    @Test("No codec forces the frame rate", arguments: FFmpegEncodingOptions.VideoCodec.allCases)
    func keepsSourceFrameRate(codec: FFmpegEncodingOptions.VideoCodec) {
        #expect(!arguments(codec).contains("-r"))
    }

    @Test("HEVC pixel format matches the encoder")
    func pixelFormat() {
        #expect(value(of: "-pix_fmt", in: arguments(.hevc)) == "yuv420p10le")
        #expect(value(of: "-pix_fmt", in: arguments(.hevcVideoToolbox)) == "p010le")
        #expect(value(of: "-tag:v", in: arguments(.hevc)) == "hvc1")
        #expect(value(of: "-tag:v", in: arguments(.hevcVideoToolbox)) == "hvc1")
        for codec in [FFmpegEncodingOptions.VideoCodec.h264, .h264VideoToolbox, .copy] {
            #expect(!arguments(codec).contains("-pix_fmt"))
        }
    }

    @Test("Output path is the last argument and extra args precede it")
    func argumentOrder() {
        var options = FFmpegEncodingOptions(videoCodec: .h264)
        options.extraArgs = ["-threads", "2"]
        let args = options.buildArguments(inputURL: input, outputURL: output, includeAudio: true)
        #expect(args.last == output.path)
        #expect(Array(args.suffix(3).prefix(2)) == ["-threads", "2"])
        #expect(value(of: "-i", in: args) == input.path)
    }

    // MARK: - Real ffmpeg (macOS, when a binary is installed)

    #if os(macOS)
    private static var ffmpegPath: String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FFMPEG_PATH"],
           fm.isExecutableFile(atPath: env) { return env }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// Run ffmpeg with the generated arguments and return the displayed output size.
    private func encodedSize(input: URL, maxResolution: ExportMaxResolution,
                             in folder: URL) async throws -> CGSize {
        let binary = try #require(Self.ffmpegPath)
        let output = folder.appendingPathComponent("\(UUID().uuidString).mp4")
        // Encode only the first second: the size is all that is checked.
        let options = FFmpegEncodingOptions(videoCodec: .h264, crf: 30, speedPreset: .ultrafast,
                                            maxResolution: maxResolution, extraArgs: ["-t", "1"])
        try await FFmpegEncoder.runFFmpeg(
            binaryPath: binary,
            arguments: options.buildArguments(inputURL: input, outputURL: output, includeAudio: false),
            totalDuration: 1,
            progressHandler: { _, _ in },
            cancellationCheck: { false }
        )
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let displayed = size.applying(transform)
        return CGSize(width: abs(displayed.width), height: abs(displayed.height))
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegArgumentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("ffmpeg output keeps the aspect ratio for 16:9, 21:9 and portrait sources",
          .enabled(if: ffmpegPath != nil, "needs an ffmpeg binary"))
    func realEncodeKeepsAspectRatio() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // 16:9: 1280×720 fixture under the SD (640×480) cap.
        let landscape = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        #expect(try await encodedSize(input: landscape, maxResolution: .SD, in: folder)
                == CGSize(width: 640, height: 360))

        // 21:9: generated 2560×1080 source under the 720p cap.
        let wide = folder.appendingPathComponent("wide.mp4")
        try await FFmpegEncoder.runFFmpeg(
            binaryPath: try #require(Self.ffmpegPath),
            arguments: ["-f", "lavfi", "-i", "testsrc=size=2560x1080:duration=0.2",
                        "-c:v", "libx264", "-preset", "ultrafast", "-y", wide.path],
            totalDuration: 0.2, progressHandler: { _, _ in }, cancellationCheck: { false }
        )
        #expect(try await encodedSize(input: wide, maxResolution: ._720p, in: folder)
                == CGSize(width: 1280, height: 540))

        // Portrait: 640×360 fixture with a 90° rotation (displayed 360×640) under the SD cap.
        // Without the portrait swap the 640×480 box would shrink it to 270×480.
        let portrait = try #require(Bundle.module.url(forResource: "rotated_portrait", withExtension: "mp4"))
        #expect(try await encodedSize(input: portrait, maxResolution: .SD, in: folder)
                == CGSize(width: 360, height: 640))
    }
    #endif
}
