import Foundation
import CoreMedia
import Testing
@testable import MosaicKit

/// Fail-fast detection of sources iOS cannot decode (implementation plan F-6, knowledge base I-22).
struct VideoCodecSupportTests {

    /// A minimal `avcC` record: version 1, the given profile, constraint flags, level 3.1.
    private func avcC(profile: UInt8) -> Data {
        Data([1, profile, 0, 31, 0xFF, 0xE0, 0])
    }

    @Test("High 10, 4:2:2 and 4:4:4 H.264 profiles are reported by name")
    func unsupportedProfilesAreNamed() {
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: avcC(profile: 110)) == "H.264 High 10")
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: avcC(profile: 122)) == "H.264 High 4:2:2")
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: avcC(profile: 244)) == "H.264 High 4:4:4 Predictive")
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: avcC(profile: 44)) == "H.264 High 4:4:4 Intra (CAVLC)")
    }

    @Test("Baseline, Main and High (8-bit 4:2:0) H.264 are decodable")
    func decodableProfiles() {
        for profile: UInt8 in [66, 77, 88, 100] {
            #expect(VideoCodecSupport.unsupportedH264Description(avcC: avcC(profile: profile)) == nil, "profile_idc \(profile)")
        }
    }

    @Test("A malformed avcC record is never reported")
    func malformedRecords() {
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: Data()) == nil)
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: Data([1, 110])) == nil)
        #expect(VideoCodecSupport.unsupportedH264Description(avcC: Data([2, 110, 0, 31])) == nil, "Unknown configuration version")
    }

    /// An H.264 format description whose `avcC` atom carries `profile`.
    private func formatDescription(profile: UInt8) throws -> CMFormatDescription {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": avcC(profile: profile)]
        ]
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 1920, height: 1080, extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        #expect(status == noErr)
        return try #require(description)
    }

    @Test("The avcC atom is read back from a format description")
    func readsAvcCFromFormatDescription() throws {
        let description = try formatDescription(profile: 110)
        #expect(VideoCodecSupport.avcC(of: description) == avcC(profile: 110))
    }

    @Test("The check is enforced on iOS only")
    func enforcedOnIOSOnly() throws {
        let high10 = try formatDescription(profile: 110)
        let high = try formatDescription(profile: 100)
        #expect(VideoCodecSupport.unsupportedCodecName(of: high) == nil)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(VideoCodecSupport.isEnforced)
        #expect(VideoCodecSupport.unsupportedCodecName(of: high10) == "H.264 High 10")
        #else
        #expect(!VideoCodecSupport.isEnforced)
        #expect(VideoCodecSupport.unsupportedCodecName(of: high10) == nil, "macOS decodes High 10")
        #endif
    }

    @Test("The embedded 8-bit fixture still inspects")
    func fixtureStillInspects() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        #expect(video.duration != nil)
    }

    @Test("unsupportedCodec names the file and codec and suggests re-encoding")
    func errorMessage() {
        let url = URL(fileURLWithPath: "/tmp/clips/drone.mp4")
        let error = VideoError.unsupportedCodec(url, "H.264 High 10")
        #expect(error.errorDescription?.contains("drone.mp4") == true)
        #expect(error.errorDescription?.contains("H.264 High 10") == true)
        #expect(error.recoverySuggestion?.contains("Re-encode") == true)
        #expect(error.associatedURL == url)
        #expect(error.underlyingError == nil)
        #expect(error == VideoError.unsupportedCodec(url, "H.264 High 10"))
        #expect(error != VideoError.unsupportedCodec(url, "H.264 High 4:2:2"))
    }
}
