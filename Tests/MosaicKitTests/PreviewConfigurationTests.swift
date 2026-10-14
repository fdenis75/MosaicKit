import Foundation
import AVFoundation
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
        #expect(defaultConfig.minimumExtractDuration == nil)
        #expect(defaultConfig.maximumPlaybackSpeed == nil)

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

    @Test("Default preview filename is deterministic (I-12)")
    func defaultFilenameIsDeterministic() async {
        let video = await makeVideoInput(path: "/tmp/preview-tests/source clip.mov")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(3_700)

        for fullPath in [false, true] {
            var config = PreviewConfiguration()
            config.fullPathInName = fullPath
            #expect(config.generateFilename(for: video, referenceDate: earlier)
                    == config.generateFilename(for: video, referenceDate: later))
            #expect(config.generateFilename(for: video) == config.generateFilename(for: video))
        }

        let name = PreviewConfiguration().generateFilename(for: video)
        #expect(name.hasPrefix("_preview_source_clip_"))
        #expect(name.wholeMatch(of: /.*\d{4}-\d{2}-\d{2}.*/) == nil, "Default name still has a date: \(name)")
    }

    @Test("filenameTemplate {time} is an opt-in run timestamp (I-12)")
    func filenameTemplateTimeToken() async {
        let video = await makeVideoInput(path: "/tmp/preview-tests/source clip.mov")
        var config = PreviewConfiguration()
        config.filenameTemplate = "{name}_{time}"
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let a = config.generateFilename(for: video, referenceDate: first)
        let b = config.generateFilename(for: video, referenceDate: first.addingTimeInterval(61))
        #expect(a != b)
        #expect(a.wholeMatch(of: /source_clip_\d{2}-\d{2}-\d{2}\.\w+/) != nil, "Got \(a)")
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

    // MARK: - Quality to preset mapping (I-5, I-6)

    @Test("Native preset follows ranges: every quality gets a preset, none falls through by float luck (I-5)")
    func nativePresetRanges() {
        let format = VideoFormat.mp4
        // The values the old exact matching handled keep their preset.
        #expect(format.exportPreset(quality: 1.0) == AVAssetExportPresetHEVCHighestQuality)
        #expect(format.exportPreset(quality: 0.9) == AVAssetExportPresetHEVC1920x1080)
        #expect(format.exportPreset(quality: 0.8) == AVAssetExportPresetHighestQuality)
        #expect(format.exportPreset(quality: 0.7) == AVAssetExportPreset1920x1080)
        #expect(format.exportPreset(quality: 0.5) == AVAssetExportPresetLowQuality)
        #expect(format.exportPreset(quality: 0.4) == AVAssetExportPreset960x540)
        // Values that used to fall through to Passthrough now land in their range.
        #expect(format.exportPreset(quality: 0.85) == AVAssetExportPresetHEVC1920x1080)
        #expect(format.exportPreset(quality: 0.77) == AVAssetExportPresetHighestQuality)
        #expect(format.exportPreset(quality: 0.6) == AVAssetExportPresetMediumQuality)
        #expect(format.exportPreset(quality: 0.45) == AVAssetExportPresetLowQuality)
        #expect(format.exportPreset(quality: 0.35) == AVAssetExportPreset960x540)
        #expect(format.exportPreset(quality: 0.3) == AVAssetExportPresetPassthrough)
        #expect(format.exportPreset(quality: 0.0) == AVAssetExportPresetPassthrough)
        // Only the lowest range is passthrough.
        for step in 35...100 {
            #expect(format.exportPreset(quality: Double(step) / 100) != AVAssetExportPresetPassthrough, "quality \(step)%")
        }
    }

    @Test("SJS quality tiers cover the whole range (I-6)")
    func sjsQualityTiers() {
        #expect(PreviewQualityTier(quality: 1.0) == .hevc)
        #expect(PreviewQualityTier(quality: 0.9) == .hevc)
        #expect(PreviewQualityTier(quality: 0.75) == .h264High)
        #expect(PreviewQualityTier(quality: 0.7) == .h264High)
        #expect(PreviewQualityTier(quality: 0.5) == .h264Main)
        #expect(PreviewQualityTier(quality: 0.4) == .h264Main)
        #expect(PreviewQualityTier(quality: 0.25) == .h264Baseline)
        #expect(PreviewQualityTier(quality: 0.0) == .h264Baseline)
    }

    @Test("SJS export description matches the exporter when no preset is set (I-6)")
    func sjsDescriptionWithoutPreset() {
        var config = PreviewConfiguration(exportMode: .sjs)
        config.sJSExportPresetName = nil
        for (quality, profile) in [(0.5, "Main"), (0.8, "High"), (0.1, "Baseline")] {
            config.compressionQuality = quality
            let description = config.exportDescription
            #expect(description.videoCodec == .h264, "quality \(quality)")
            #expect(description.videoProfile == profile, "quality \(quality)")
        }
        config.compressionQuality = 1.0
        #expect(config.exportDescription.videoCodec == .hevc)
        // An explicit preset still wins.
        config.sJSExportPresetName = .h264_lowAutoLevel
        #expect(config.exportDescription.videoProfile == "Baseline")
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
                                    #expect(outputDir.path == "/tmp/preview-output")

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
        var fastConfig = PreviewConfiguration(targetDuration: 30, density: .xxs, compressionQuality: 0.8)
        fastConfig.minimumExtractDuration = 4.0
        fastConfig.maximumPlaybackSpeed = 1.5
        let fastParams = fastConfig.calculateExtractParameters(forVideoDuration: 10_800)
        let fastMinimumExtractDuration = try #require(fastConfig.minimumExtractDuration)
        let fastMaximumPlaybackSpeed = try #require(fastConfig.maximumPlaybackSpeed)
        #expect(fastParams.extractDuration > 0)
        #expect(fastParams.extractDuration <= fastMinimumExtractDuration)
        #expect(fastParams.playbackSpeed <= fastMaximumPlaybackSpeed)
        #expect(fastParams.playbackSpeed >= 1.0)

        var relaxedConfig = PreviewConfiguration(targetDuration: 300, density: .xxl, compressionQuality: 0.8)
        relaxedConfig.minimumExtractDuration = 4.0
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
