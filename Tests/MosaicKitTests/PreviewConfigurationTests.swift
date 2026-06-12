import Foundation
import Testing
@testable import MosaicKit

struct PreviewConfigurationTests {
    @Test("PreviewConfiguration clamps compression quality")
    func compressionQualityClamp() {
        let low = PreviewConfiguration(compressionQuality: -1.0)
        let high = PreviewConfiguration(compressionQuality: 10.0)
        let normal = PreviewConfiguration(compressionQuality: 0.42)

        #expect(low.compressionQuality == 0.0)
        #expect(high.compressionQuality == 1.0)
        #expect(normal.compressionQuality == 0.42)
    }

    @Test("PreviewConfiguration exposes optional extract timing controls")
    func optionalExtractTimingControls() async throws {
        let defaultConfig = PreviewConfiguration()
        #expect(defaultConfig.minimumExtractDuration == 4.0)
        #expect(defaultConfig.maximumPlaybackSpeed == 1.5)

        let disabledConfig = PreviewConfiguration(
            targetDuration: 30,
            minimumExtractDuration: nil,
            maximumPlaybackSpeed: nil,
            density: .xxs
        )
        let params = disabledConfig.calculateExtractParameters(forVideoDuration: 10_800)
        #expect(params.playbackSpeed == 1.0)
        #expect(params.extractDuration > 0)

        let data = try JSONEncoder().encode(disabledConfig)
        let decoded = try JSONDecoder().decode(PreviewConfiguration.self, from: data)
        #expect(decoded.minimumExtractDuration == nil)
        #expect(decoded.maximumPlaybackSpeed == nil)

        let video = await makeVideoInput(path: "/tmp/preview-tests/source clip.mov")
        let defaultFilename = defaultConfig.generateFilename(for: video)
        let customFilename = PreviewConfiguration(
            minimumExtractDuration: 2.5,
            maximumPlaybackSpeed: 2.0
        ).generateFilename(for: video)
        #expect(customFilename != defaultFilename)
        #expect(customFilename.contains("min2p5s_max2x"))
    }

    @Test("PreviewConfiguration base extract count map matches density")
    func baseExtractCountMap() {
        #expect(PreviewConfiguration(density: .xxl).baseExtractCount == 4)
        #expect(PreviewConfiguration(density: .xl).baseExtractCount == 8)
        #expect(PreviewConfiguration(density: .l).baseExtractCount == 12)
        #expect(PreviewConfiguration(density: .m).baseExtractCount == 16)
        #expect(PreviewConfiguration(density: .s).baseExtractCount == 24)
        #expect(PreviewConfiguration(density: .xs).baseExtractCount == 32)
        #expect(PreviewConfiguration(density: .xxs).baseExtractCount == 48)
    }

    @Test("PreviewConfiguration exportDescription is mode-agnostic across native/sjs/ffmpeg")
    func exportDescriptionAcrossModes() {
        // Native: preset's own resolution is authoritative.
        var native = PreviewConfiguration(exportMode: .native, exportPresetName: .AVAssetExportPresetHEVC1920x1080)
        var description = native.exportDescription
        #expect(description.exportMode == .native)
        #expect(description.videoCodec == .hevc)
        #expect(description.videoProfile == "Main")
        #expect(description.videoLevel == "4.0")
        #expect(description.maxResolution == CGSize(width: 1920, height: 1080))

        // Native passthrough: no codec; falls back to the configured `exportMaxResolution` cap
        // (default 1080p) since the preset itself preserves source resolution.
        native = PreviewConfiguration(exportMode: .native, exportPresetName: .AVAssetExportPresetPassthrough)
        description = native.exportDescription
        #expect(description.videoCodec == nil)
        #expect(description.maxResolution == CGSize(width: 1920, height: 1080))

        // SJS: codec/profile/level derived from the SJS preset's H264Profile.
        let sjs = PreviewConfiguration(exportMode: .sjs, sjSExportPresetName: .h264_HighAutoLevel)
        description = sjs.exportDescription
        #expect(description.exportMode == .sjs)
        #expect(description.videoCodec == .h264)
        #expect(description.videoProfile == "High")
        #expect(description.videoLevel == "Auto")

        // FFmpeg: derived from FFmpegEncodingOptions, including resolution cap.
        let ffmpeg = PreviewConfiguration(
            exportMode: .ffmpeg,
            ffmpegEncodingOptions: FFmpegEncodingOptions(videoCodec: .hevc, crf: 20, maxResolution: ._1080p)
        )
        description = ffmpeg.exportDescription
        #expect(description.exportMode == .ffmpeg)
        #expect(description.videoCodec == .hevc)
        #expect(description.maxResolution == CGSize(width: 1920, height: 1080))
        #expect(description.additionalDetail?.contains("CRF 20") == true)
    }

    @Test("PreviewConfiguration showTimestampOverlay defaults to false and round-trips")
    func showTimestampOverlayDefaultsAndRoundTrips() throws {
        let config = PreviewConfiguration()
        #expect(config.showTimestampOverlay == false)

        var enabled = config
        enabled.showTimestampOverlay = true
        let data = try JSONEncoder().encode(enabled)
        let decoded = try JSONDecoder().decode(PreviewConfiguration.self, from: data)
        #expect(decoded.showTimestampOverlay == true)
    }

    @Test("PreviewConfiguration combinations are codable and produce valid filenames")
    func codableAndFilenameCombinations() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let video = await makeVideoInput(path: "/tmp/preview-tests/source clip.mov")

        let formats = VideoFormat.allCases
        let bools = [true, false]
        let qualityValues: [Double] = [0.0, 0.5, 1.0]
        let durations: [TimeInterval] = [30, 60, 150]

        var checked = 0

        for density in DensityConfig.allCases {
            for format in formats {
                for includeAudio in bools {
                    for fullPathInName in bools {
                        for useNativeExport in bools {
                            for quality in qualityValues {
                                for duration in durations {
                                    // ExportMaxResolution requires macOS 26+; use the
                                    // base init and set the property conditionally.
                                    var config = PreviewConfiguration(
                                        targetDuration: duration,
                                        density: density,
                                        format: format,
                                        includeAudio: includeAudio,
                                        outputDirectory: URL(fileURLWithPath: "/tmp/preview-output"),
                                        fullPathInName: fullPathInName,
                                        compressionQuality: quality,
                                        useNativeExport: useNativeExport,
                                        exportPresetName: useNativeExport ? .AVAssetExportPresetHighestQuality : nil,
                                        sjSExportPresetName: useNativeExport ? .hevc : .h264_HighAutoLevel
                                    )
                                    if #available(macOS 26, iOS 26, *) {
                                        config.exportMaxResolution = useNativeExport ? ._1080p : ._720p
                                    }

                                    let data = try encoder.encode(config)
                                    let decoded = try decoder.decode(PreviewConfiguration.self, from: data)

                                    #expect(decoded.targetDuration == config.targetDuration)
                                    #expect(decoded.density == config.density)
                                    #expect(decoded.format == config.format)
                                    #expect(decoded.includeAudio == config.includeAudio)
                                    #expect(decoded.fullPathInName == config.fullPathInName)
                                    #expect(decoded.compressionQuality >= 0.0)
                                    #expect(decoded.compressionQuality <= 1.0)
                                    #expect(decoded.extractCount(forVideoDuration: 600) > 0)

                                    let filename = decoded.generateFilename(for: video)
                                    #expect(filename.contains("_preview_"))
                                    #expect(filename.hasSuffix(".\(format.fileExtension)"))

                                    let outputDir = decoded.generateOutputDirectory(for: video)
                                    #expect(outputDir.path.hasSuffix("/movieprev"))

                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(checked > 0)
    }

    @Test("Preview extract parameter calculation honors min duration and speed cap")
    func extractParameterCalculation() throws {
        let fastConfig = PreviewConfiguration(
            targetDuration: 30,
            density: .xxs,
            compressionQuality: 0.8
        )
        let fastParams = fastConfig.calculateExtractParameters(forVideoDuration: 10_800)
        let fastMinimumExtractDuration = try #require(fastConfig.minimumExtractDuration)
        let fastMaximumPlaybackSpeed = try #require(fastConfig.maximumPlaybackSpeed)
        #expect(fastParams.extractDuration > 0)
        #expect(fastParams.extractDuration <= fastMinimumExtractDuration)
        #expect(fastParams.playbackSpeed <= fastMaximumPlaybackSpeed)
        #expect(fastParams.playbackSpeed >= 1.0)

        let relaxedConfig = PreviewConfiguration(
            targetDuration: 300,
            density: .xxl,
            compressionQuality: 0.8
        )
        let relaxedParams = relaxedConfig.calculateExtractParameters(forVideoDuration: 300)
        let relaxedMinimumExtractDuration = try #require(relaxedConfig.minimumExtractDuration)
        #expect(relaxedParams.playbackSpeed == 1.0)
        #expect(relaxedParams.extractDuration >= relaxedMinimumExtractDuration)
    }

    @Test("Preview helper static methods are consistent")
    func staticHelpers() {
        #expect(PreviewConfiguration.exterEtractCount(density: "M") == 16)
        #expect(PreviewConfiguration.extractCountExt(forVideoDuration: 600, density: "M", targetDuration: 60) > 16)
        #expect(PreviewConfiguration.durationLabel(for: 90) == "1:30")
    }

    private func makeVideoInput(path: String) async -> VideoInput {
        await VideoInput(
            url: URL(fileURLWithPath: path),
            title: "Preview Source",
            duration: 600,
            width: 1920,
            height: 1080,
            frameRate: 30,
            fileSize: 3_000_000,
            metadata: VideoMetadata(codec: "hevc", bitrate: 2_000_000, custom: [:]),
            postID: "post123"
        )
    }
}
