import Foundation
import Testing
@testable import MosaicKit

/// Pinned configuration payloads (implementation plan P-2c, knowledge base I-24).
///
/// Apps persist `MosaicConfiguration` and `PreviewConfiguration` as JSON. These fixtures
/// freeze what released versions wrote, so a change to either decoder that breaks saved
/// configurations fails here instead of in users' apps:
///
/// - `*-1.7.0.json`: payloads in the shape 1.7.0 encodes (the config models are unchanged
///   from 1.7.0 through 1.7.4), with non-default values so every field is exercised.
/// - `*-legacy-minimal.json`: only the keys each decoder requires today. `MosaicConfiguration`
///   decodes most keys strictly (I-24), so adding a required key makes this test fail; add
///   new keys with `decodeIfPresent` plus a default instead (rules card #2).
/// - `mosaic-config-1.3.2.json`: the shape 1.3.2 encoded, the last release before `gifFps`
///   (added in 1.4.0) and `createOutputSubdirectory`. It does not decode today because
///   `gifFps` is still required (I-24); plan step S-5 fixes that and must remove the
///   `withKnownIssue` wrapper (Swift Testing fails the test once the issue stops reproducing).
///
/// Never edit these fixtures to make a test pass: that would hide exactly the breakage
/// they exist to catch.
struct LegacyConfigurationDecodingTests {

    // MARK: - MosaicConfiguration

    @Test("A MosaicConfiguration saved by 1.7.0 decodes with every value intact")
    func mosaicConfiguration170Decodes() throws {
        let config = try JSONDecoder().decode(MosaicConfiguration.self, from: try fixture("mosaic-config-1.7.0"))

        #expect(config.width == 10_000)
        #expect(config.density == .xs)
        #expect(config.format == .jpeg)
        #expect(config.layout.aspectRatio == .ultrawide)
        #expect(config.layout.layoutType == .classic)
        #expect(config.layout.spacing == 6)
        #expect(config.layout.visual.addBorder)
        #expect(config.layout.visual.borderColor == .black)
        #expect(config.layout.visual.shadowSettings?.offset == CGSize(width: 0, height: -2))
        #expect(config.includeMetadata)
        #expect(config.useAccurateTimestamps)
        #expect(config.compressionQuality == 0.6)
        #expect(config.outputdirectory?.absoluteString == "file:///tmp/MosaicKitLegacy/")
        #expect(config.fullPathInName)
        #expect(!config.useMovieColorsForBg)
        #expect(config.backgroundColor == MosaicColor(red: 0.05, green: 0.1, blue: 0.2))
        #expect(config.overlay.frameLabel.format == .frameIndex)
        #expect(config.overlay.frameLabel.position == .topLeft)
        #expect(config.overlay.frameLabel.backgroundStyle == .fullWidth)
        #expect(config.overlay.header.fields == [
            .title, .duration, .resolution, .colorPalette(swatchCount: 5), .custom(label: "Series", value: "Pilot"),
        ])
        #expect(config.overlay.header.height == .fixed(80))
        #expect(config.overlay.watermark?.position == .bottomRight)
        if case .text(let text)? = config.overlay.watermark?.content {
            #expect(text == "© MosaicKit")
        } else {
            Issue.record("Expected a text watermark")
        }
        #expect(config.overlay.colorDNA.show)
        #expect(config.overlay.colorDNA.style == .gradient)
        #expect(config.gifMode == .withMosaic)
        #expect(config.gifSize == .large)
        #expect(config.animatedFormat == .gif)
        #expect(config.gifFps == 12)
        #expect(config.overwrite)
        #expect(!config.createOutputSubdirectory)
        #expect(config.outputDirectoryTemplate == "{root}/{density}")
        #expect(config.filenameTemplate == "{name}-{width}.{ext}")
    }

    @Test("A MosaicConfiguration with only today's required keys still decodes, with defaults")
    func mosaicConfigurationMinimalDecodes() throws {
        let config = try JSONDecoder().decode(MosaicConfiguration.self, from: try fixture("mosaic-config-legacy-minimal"))

        #expect(config.density == .m) // resolved from `factor` alone
        #expect(config.outputdirectory == nil)
        #expect(config.overlay.watermark == nil)
        #expect(config.createOutputSubdirectory) // key added after configs were persisted
        #expect(config.outputDirectoryTemplate == nil)
        #expect(config.filenameTemplate == nil)
    }

    @Test("A MosaicConfiguration saved by 1.3.2 (before gifFps) decodes with defaults (I-24)")
    func mosaicConfiguration132Decodes() throws {
        let data = try fixture("mosaic-config-1.3.2")

        withKnownIssue("I-24: gifFps is decoded strictly, so pre-1.4.0 configs fail (fixed by plan step S-5)") {
            let config = try JSONDecoder().decode(MosaicConfiguration.self, from: data)
            #expect(config.width == 4000)
            #expect(config.density == .s) // resolved from `factor` alone, as 1.3.2 wrote it
            #expect(config.format == .png)
            #expect(config.layout.aspectRatio == .standard)
            #expect(config.layout.layoutType == .classic)
            #expect(config.layout.visual.borderColor == .gray)
            #expect(config.outputdirectory?.absoluteString == "file:///tmp/MosaicKit132/")
            #expect(config.overlay.header.fields == [.title, .codec])
            #expect(config.overlay.colorDNA.position == .top)
            #expect(config.gifMode == .gifOnly)
            #expect(config.animatedFormat == .heic)
            #expect(config.overwrite)
            #expect(config.filenameTemplate == "{name}.{ext}")
            #expect(config.gifFps == 10) // keys added after 1.3.2 take their defaults
            #expect(config.createOutputSubdirectory)
        }
    }

    @Test("A decoded 1.7.0 MosaicConfiguration round-trips through the current encoder")
    func mosaicConfigurationRoundTrips() throws {
        let original = try JSONDecoder().decode(MosaicConfiguration.self, from: try fixture("mosaic-config-1.7.0"))
        let decoded = try JSONDecoder().decode(MosaicConfiguration.self, from: try JSONEncoder().encode(original))
        #expect(decoded.configurationHash == original.configurationHash)
        #expect(decoded.overlay.header.fields == original.overlay.header.fields)
        #expect(decoded.outputDirectoryTemplate == original.outputDirectoryTemplate)
    }

    // MARK: - PreviewConfiguration

    @Test("A PreviewConfiguration saved by 1.7.0 decodes with every value intact")
    func previewConfiguration170Decodes() throws {
        let config = try JSONDecoder().decode(PreviewConfiguration.self, from: try fixture("preview-config-1.7.0"))

        #expect(config.targetDuration == 30)
        #expect(config.minimumExtractDuration == 2)
        #expect(config.maximumPlaybackSpeed == 1.5)
        #expect(config.density == .xl)
        #expect(config.format == .mov)
        #expect(!config.includeAudio)
        #expect(config.outputDirectory?.absoluteString == "file:///tmp/MosaicKitLegacyPreviews/")
        #expect(config.compressionQuality == 0.7)
        #expect(config.exportMode == .sjs)
        #expect(config.exportPresetName == .AVAssetExportPresetHEVC1920x1080)
        #expect(config.sJSExportPresetName == .hevc)
        #expect(config.exportMaxResolutionRaw == "720p")
        #expect(config.ffmpegBinaryPath == "/opt/homebrew/bin/ffmpeg")
        #expect(config.overwrite)
        #expect(config.outputDirectoryTemplate == "{root}/previews")
        #expect(config.filenameTemplate == "{name}-preview.{ext}")
        #expect(!config.enableAppLifecycleMonitor)
        #expect(!config.enableExportRetry)
        #expect(config.showTimestampOverlay)
    }

    @Test("A pre-exportMode PreviewConfiguration maps useNativeExport and fills defaults")
    func previewConfigurationLegacyMinimalDecodes() throws {
        let config = try JSONDecoder().decode(PreviewConfiguration.self, from: try fixture("preview-config-legacy-minimal"))

        #expect(config.exportMode == .sjs) // useNativeExport: false
        #expect(config.density == .m)
        #expect(config.exportPresetName == nil)
        #expect(config.sJSExportPresetName == .hevc)
        #expect(config.exportMaxResolutionRaw == "1080p")
        #expect(!config.overwrite)
        #expect(config.enableAppLifecycleMonitor)
        #expect(config.enableExportRetry)
        #expect(!config.showTimestampOverlay)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"),
                               "Missing test fixture \(name).json")
        return try Data(contentsOf: url)
    }
}
