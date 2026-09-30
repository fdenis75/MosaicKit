import Foundation
import Testing
@testable import MosaicKit

/// The secondary and deprecated initializers delegate to each type's designated initializer
/// (plan step S-5). These pin the values each one sets, so the delegation cannot drift.
struct ConfigurationInitializerTests {

    @Test("The short MosaicConfiguration initializer keeps its 2500 px, q0.3, solid-background preset")
    func shortMosaicInitializer() {
        let config = MosaicConfiguration(density: .l, fullPathInName: true, gifMode: .withMosaic,
                                         gifSize: .large, animatedFormat: .gif, gifFps: 12)
        #expect(config.width == 2500)
        #expect(config.density == .l)
        #expect(config.format == .heif)
        #expect(config.compressionQuality == 0.3)
        #expect(config.includeMetadata)
        #expect(!config.useMovieColorsForBg)
        #expect(config.fullPathInName)
        #expect(config.gifMode == .withMosaic)
        #expect(config.gifSize == .large)
        #expect(config.animatedFormat == .gif)
        #expect(config.gifFps == 12)
        #expect(!config.overwrite)
        #expect(config.createOutputSubdirectory)
    }

    @Test("The MosaicConfiguration initializer without animation parameters disables animation at .small")
    func noAnimationMosaicInitializer() {
        let config = MosaicConfiguration(width: 3200, density: .s, format: .jpeg, layout: .default,
                                         includeMetadata: false, useAccurateTimestamps: true,
                                         compressionQuality: 0.7, outputdirectory: nil,
                                         fullPathInName: false, useMovieColorsForBg: true,
                                         backgroundColor: .defaultGray, overlay: .default, gifFps: 8)
        #expect(config.width == 3200)
        #expect(config.format == .jpeg)
        #expect(!config.includeMetadata)
        #expect(config.useAccurateTimestamps)
        #expect(config.compressionQuality == 0.7)
        #expect(config.gifMode == .disabled)
        #expect(config.gifSize == .small)
        #expect(config.animatedFormat == .webp)
        #expect(config.gifFps == 8)
    }

    @available(*, deprecated)
    @Test("The deprecated forIphone MosaicConfiguration initializer maps forIphone to a solid background")
    func deprecatedForIphoneInitializer() {
        let iphone = MosaicConfiguration(width: 1200, forIphone: true)
        #expect(iphone.width == 1200)
        #expect(!iphone.useMovieColorsForBg)
        #expect(iphone.backgroundColor == .defaultGray)
        #expect(iphone.gifMode == .disabled)
        #expect(iphone.gifSize == .nochange)
        #expect(iphone.animatedFormat == .gif)
        #expect(iphone.gifFps == 10)
        #expect(MosaicConfiguration(forIphone: false).useMovieColorsForBg)
    }

    @Test("The macOS 26 PreviewConfiguration initializer sets maxResolution, defaulting to 1080p (D3)")
    func previewMaxResolutionInitializer() {
        let capped = PreviewConfiguration(targetDuration: 30, exportMode: .sjs, maxResolution: ._720p,
                                          enableAppLifecycleMonitor: false)
        #expect(capped.exportMaxResolutionRaw == "720p")
        #expect(capped.targetDuration == 30)
        #expect(capped.exportMode == .sjs)
        #expect(!capped.enableAppLifecycleMonitor)

        let unset = PreviewConfiguration(targetDuration: 30, exportMode: .sjs, maxResolution: nil)
        #expect(unset.exportMaxResolutionRaw == "1080p")
        #expect(PreviewConfiguration().exportMaxResolutionRaw == "1080p")
    }

    @available(*, deprecated)
    @Test("The deprecated useNativeExport PreviewConfiguration initializer maps to exportMode")
    func deprecatedUseNativeExportInitializer() {
        let native = PreviewConfiguration(targetDuration: 20, compressionQuality: 1.7, useNativeExport: true)
        #expect(native.exportMode == .native)
        #expect(native.targetDuration == 20)
        #expect(native.compressionQuality == 1.0) // still clamped
        #expect(native.ffmpegBinaryPath == nil)
        #expect(native.enableAppLifecycleMonitor)
        #expect(native.enableExportRetry)
        #expect(native.exportMaxResolutionRaw == "1080p")

        let sjs = PreviewConfiguration(useNativeExport: false, sjSExportPresetName: nil)
        #expect(sjs.exportMode == .sjs)
        #expect(sjs.sJSExportPresetName == .hevc)
    }
}
