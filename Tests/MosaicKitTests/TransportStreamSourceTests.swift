import Foundation
import Testing
@testable import MosaicKit

/// I-38: MPEG transport streams, with and without a file extension.
/// `test_stream.ts` is 6 s of 320×180 H.264 (8-bit 4:2:0) in TS; `hevc_stream.ts` is the same in
/// HEVC, which AVFoundation's TS demuxer can't read. No network I/O.
/// AVFoundation decodes H.264 TS on macOS only; on iOS every transport stream gives the error.
#if os(macOS)
let transportStreamDecodes = true
#else
let transportStreamDecodes = false
#endif

@Suite("MPEG-TS sources")
struct TransportStreamSourceTests {
    private static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "ts"))
    }

    /// A copy of `source` with no file extension, in a new temporary folder.
    private static func extensionlessCopy(of source: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitTS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("download")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    // MARK: Sniffing

    @Test("Leading bytes identify TS, M2TS and MP4; anything else is unknown")
    func sniffing() throws {
        let ts = try Data(contentsOf: Self.fixture("test_stream"))
        #expect(ContainerSniffer.container(of: ts) == .transportStream)

        // 192-byte M2TS packets: a 4-byte timestamp, then the 0x47 sync byte.
        var m2ts = Data()
        for _ in 0..<5 { m2ts.append(contentsOf: [0, 0, 0, 0, 0x47] + [UInt8](repeating: 0xFF, count: 187)) }
        #expect(ContainerSniffer.container(of: m2ts) == .transportStream)

        let mp4URL = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let mp4 = try #require(try FileHandle(forReadingFrom: mp4URL).read(upToCount: 1024))
        #expect(ContainerSniffer.container(of: mp4) == .mpeg4)

        // One sync byte is not enough, and a broken second packet is not a stream.
        #expect(ContainerSniffer.container(of: Data([0x47] + [UInt8](repeating: 0, count: 100))) == .unknown)
        var broken = ts.prefix(1024)
        broken[broken.startIndex + 188] = 0
        #expect(ContainerSniffer.container(of: broken) == .unknown)
        #expect(ContainerSniffer.container(of: Data("RIFF....AVI LIST".utf8)) == .unknown)
        #expect(ContainerSniffer.container(of: Data()) == .unknown)
    }

    @Test("An extensionless local file is sniffed; a known extension is never read")
    func localSniff() async throws {
        let copy = try Self.extensionlessCopy(of: Self.fixture("test_stream"))
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        #expect(await RemoteVideoSupport.overrideMIMEType(for: copy) == "video/mp2t")
        let withExtension = try Self.fixture("test_stream")
        #expect(await RemoteVideoSupport.sourceContainer(for: withExtension) == nil)
    }

    // MARK: End to end

    @Test("A mosaic is made from an H.264 transport stream, with and without its extension",
          .enabled(if: transportStreamDecodes, "AVFoundation on iOS doesn't read transport streams"))
    func mosaicFromTransportStream() async throws {
        let source = try Self.fixture("test_stream")
        let copy = try Self.extensionlessCopy(of: source)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        var config = MosaicConfiguration(width: 640, density: .xxl, format: .jpeg, includeMetadata: false)
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        for url in [source, copy] {
            let video = try await VideoInput(from: url)
            #expect(video.width == 320 && video.height == 180)
            let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
            #expect(image.width == 640, "\(url.lastPathComponent): \(image.width) x \(image.height)")
        }
    }

    @Test("H.264 in a transport stream fails with the same error where TS can't be read",
          .enabled(if: !transportStreamDecodes, "macOS reads H.264 TS"))
    func h264TransportStreamErrorOnIOS() async throws {
        let url = try Self.fixture("test_stream")
        await #expect(throws: VideoError.unsupportedCodec(url, RemoteVideoSupport.unreadableTransportStreamDescription)) {
            _ = try await VideoInput(from: url)
        }
    }

    @Test("HEVC in a transport stream fails with a clear unsupported-codec error")
    func hevcTransportStreamError() async throws {
        let source = try Self.fixture("hevc_stream")
        let copy = try Self.extensionlessCopy(of: source)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        for url in [source, copy] {
            do {
                _ = try await VideoInput(from: url)
                Issue.record("\(url.lastPathComponent) opened")
            } catch let error as VideoError {
                guard case .unsupportedCodec(let failing, let codec) = error else {
                    Issue.record("Unexpected error \(error)"); continue
                }
                #expect(failing == url)
                #expect(codec == RemoteVideoSupport.unreadableTransportStreamDescription)
            }
        }
    }

    @Test("A known-metadata HEVC stream fails before frame extraction with the same error")
    func hevcKnownMetadataError() async throws {
        let url = try Self.fixture("hevc_stream")
        let video = VideoInput(canonicalID: UUID(), url: url, title: "hevc", duration: 6, width: 320, height: 180)
        var config = MosaicConfiguration(width: 640, density: .xxl, format: .jpeg, includeMetadata: false)
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        let error = await #expect(throws: VideoError.self) {
            _ = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
        }
        guard case .unsupportedCodec = error else {
            Issue.record("Unexpected error \(String(describing: error))"); return
        }
    }
}
