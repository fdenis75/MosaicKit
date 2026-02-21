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

    @Test("PreviewConfiguration combinations are codable and produce valid filenames")
    func codableAndFilenameCombinations() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let video = makeVideoInput(path: "/tmp/preview-tests/source clip.mov")

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
                                    let config = PreviewConfiguration(
                                        targetDuration: duration,
                                        density: density,
                                        format: format,
                                        includeAudio: includeAudio,
                                        outputDirectory: URL(fileURLWithPath: "/tmp/preview-output"),
                                        fullPathInName: fullPathInName,
                                        compressionQuality: quality,
                                        useNativeExport: useNativeExport,
                                        exportPresetName: useNativeExport ? .AVAssetExportPresetHighestQuality : nil,
                                        sjSExportPresetName: useNativeExport ? .hevc : .h264_HighAutoLevel,
                                        maxResolution: useNativeExport ? ._1080p : ._720p
                                    )

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
    func extractParameterCalculation() {
        let fastConfig = PreviewConfiguration(
            targetDuration: 30,
            density: .xxs,
            compressionQuality: 0.8
        )
        let fastParams = fastConfig.calculateExtractParameters(forVideoDuration: 10_800)
        #expect(fastParams.extractDuration > 0)
        #expect(fastParams.extractDuration <= PreviewConfiguration.minimumExtractDuration)
        #expect(fastParams.playbackSpeed <= PreviewConfiguration.maximumPlaybackSpeed)
        #expect(fastParams.playbackSpeed >= 1.0)

        let relaxedConfig = PreviewConfiguration(
            targetDuration: 300,
            density: .xxl,
            compressionQuality: 0.8
        )
        let relaxedParams = relaxedConfig.calculateExtractParameters(forVideoDuration: 300)
        #expect(relaxedParams.playbackSpeed == 1.0)
        #expect(relaxedParams.extractDuration >= PreviewConfiguration.minimumExtractDuration)
    }

    @Test("Preview helper static methods are consistent")
    func staticHelpers() {
        #expect(PreviewConfiguration.exterEtractCount(density: "M") == 16)
        #expect(PreviewConfiguration.extractCountExt(forVideoDuration: 600, density: "M", targetDuration: 60) > 16)
        #expect(PreviewConfiguration.durationLabel(for: 90) == "1:30")
    }

    private func makeVideoInput(path: String) -> VideoInput {
        VideoInput(
            url: URL(fileURLWithPath: path),
            title: "Preview Source",
            duration: 600,
            width: 1920,
            height: 1080,
            frameRate: 30,
            fileSize: 3_000_000,
            metadata: VideoMetadata(codec: "hevc", bitrate: 2_000_000, custom: [:]),
            serviceName: "svc",
            creatorName: "creator",
            postID: "post123"
        )
    }
}
