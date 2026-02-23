import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

struct MosaicConfigurationTests {
    @Test("MosaicConfiguration default values are stable")
    func defaultValues() {
        let config = MosaicConfiguration.default

        #expect(config.width == 4000)
        #expect(config.density == .xl)
        #expect(config.format == .heif)
        #expect(config.layout.layoutType == .custom)
        #expect(config.includeMetadata == true)
        #expect(config.useAccurateTimestamps == false)
        #expect(config.compressionQuality == 0.4)
        #expect(config.useMovieColorsForBg == true)
    }

    @Test("MosaicConfiguration combinations round-trip through Codable")
    func codableCombinations() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let formats: [OutputFormat] = [.jpeg, .png, .heif]
        let metadataOptions = [true, false]
        let accurateOptions = [true, false]
        let fullPathOptions = [true, false]
        let movieColorOptions = [true, false]

        var checked = 0

        for density in DensityConfig.allCases {
            for format in formats {
                for aspect in AspectRatio.allCases {
                    for layoutType in [LayoutType.auto, .custom, .dynamic, .classic, .iphone] {
                        for includeMetadata in metadataOptions {
                            for accurate in accurateOptions {
                                for fullPath in fullPathOptions {
                                    for useMovieColors in movieColorOptions {
                                        var config = MosaicConfiguration(
                                            width: 4096,
                                            density: density,
                                            format: format,
                                            layout: LayoutConfiguration(
                                                aspectRatio: aspect,
                                                spacing: 6,
                                                layoutType: layoutType,
                                                visual: VisualSettings(
                                                    addBorder: true,
                                                    borderColor: .gray,
                                                    borderWidth: 2,
                                                    addShadow: true,
                                                    shadowSettings: ShadowSettings(opacity: 0.4, radius: 3, offset: CGSize(width: 2, height: -1))
                                                )
                                            ),
                                            includeMetadata: includeMetadata,
                                            useAccurateTimestamps: accurate,
                                            compressionQuality: 0.65,
                                            outputdirectory: URL(fileURLWithPath: "/tmp/mosaic-tests"),
                                            fullPathInName: fullPath,
                                            useMovieColorsForBg: useMovieColors,
                                            backgroundColor: MosaicColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
                                        )
                                        config.updateAspectRatio(new: aspect)

                                        let data = try encoder.encode(config)
                                        let decoded = try decoder.decode(MosaicConfiguration.self, from: data)

                                        #expect(decoded.width == config.width)
                                        #expect(decoded.density == config.density)
                                        #expect(decoded.format == config.format)
                                        #expect(decoded.layout.aspectRatio.rawValue == config.layout.aspectRatio.rawValue)
                                        #expect(decoded.layout.layoutType == config.layout.layoutType)
                                        #expect(decoded.layout.spacing == config.layout.spacing)
                                        #expect(decoded.includeMetadata == config.includeMetadata)
                                        #expect(decoded.useAccurateTimestamps == config.useAccurateTimestamps)
                                        #expect(decoded.fullPathInName == config.fullPathInName)
                                        #expect(decoded.useMovieColorsForBg == config.useMovieColorsForBg)
                                        #expect(decoded.configurationHash.contains(config.density.name))

                                        checked += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(checked > 0)
    }

    @Test("MosaicConfiguration output path and filename combinations are deterministic")
    func pathAndFilenameCombinations() {
        let video = makeVideoInput(
            filePath: "/Volumes/volname/test/test.mp4",
            serviceName: "Test1",
            creatorName: "Test2",
            postID: "POST:123"
        )

        let root = URL(fileURLWithPath: "/tmp/output-root")
        let config = MosaicConfiguration(
            width: 5120,
            density: .m,
            format: .png,
            layout: LayoutConfiguration(aspectRatio: .vertical, layoutType: .dynamic),
            includeMetadata: true,
            useAccurateTimestamps: true,
            compressionQuality: 0.5,
            outputdirectory: nil,
            fullPathInName: false,
            useMovieColorsForBg: false,
            backgroundColor: .defaultGray
        )

        let outputDirectory = config.generateOutputDirectory(rootDirectory: root, videoInput: video)
        #expect(outputDirectory.path.contains("Test1"))
        #expect(outputDirectory.path.contains("Test2"))
        #expect(outputDirectory.path.contains(config.configurationHash))

        let defaultFilename = config.generateFilename(originalFilename: "test", videoInput: video)
        #expect(defaultFilename.contains("POST_123_test"))
        #expect(defaultFilename.hasSuffix(".png"))

        let fullPathConfig = MosaicConfiguration(
            width: config.width,
            density: config.density,
            format: config.format,
            layout: config.layout,
            includeMetadata: config.includeMetadata,
            useAccurateTimestamps: config.useAccurateTimestamps,
            compressionQuality: config.compressionQuality,
            outputdirectory: config.outputdirectory,
            fullPathInName: true,
            useMovieColorsForBg: config.useMovieColorsForBg,
            backgroundColor: config.backgroundColor
        )
        let fullPathFilename = fullPathConfig.generateFilename(originalFilename: "test", videoInput: video)
        #expect(fullPathFilename.hasPrefix("_Volumes_volname_test"))
        #expect(fullPathFilename.hasSuffix(".png"))
    }

    @Test("Deprecated iPhone initializer maps to modern background settings")
    func deprecatedIphoneInitMapping() {
        let iphoneConfig = MosaicConfiguration(forIphone: true)
        let nonIphoneConfig = MosaicConfiguration(forIphone: false)

        #expect(iphoneConfig.useMovieColorsForBg == false)
        #expect(nonIphoneConfig.useMovieColorsForBg == true)
        #expect(iphoneConfig.backgroundColor == .defaultGray)
        #expect(nonIphoneConfig.backgroundColor == .defaultGray)
    }

    private func makeVideoInput (
        filePath: String,
        serviceName: String?,
        creatorName: String?,
        postID: String?
    ) -> VideoInput {
        VideoInput(
            url: URL(fileURLWithPath: filePath),
            serviceName: serviceName,
            creatorName: creatorName,
            postID: postID
        )
    }
}
