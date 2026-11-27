import Foundation
import Synchronization
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

/// Serialized: the remux tests turn ``FFmpegFallback`` on for the process, which would
/// change what the error tests see.
@Suite("MPEG-TS sources", .serialized)
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

    // MARK: Remuxing through ffmpeg (macOS)

    static var ffmpegPath: String? { TestEnvironment.ffmpegPath }

    /// Runs `body` with remuxing enabled into a new cache folder, then disables it.
    static func withRemuxer(_ body: (URL) async throws -> Void) async throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitRemuxTest-\(UUID().uuidString)", isDirectory: true)
        try FFmpegFallback.enable(ffmpegBinaryPath: try #require(ffmpegPath), cacheDirectory: cache)
        defer {
            FFmpegFallback.disable()
            try? FileManager.default.removeItem(at: cache)
        }
        try await body(cache)
    }

    private static func cachedMP4s(_ cache: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }
    }

    @Test("With the remuxer, an HEVC transport stream makes a mosaic, remuxed once",
          .enabled(if: FFmpegFallback.isSupported && ffmpegPath != nil, "needs macOS and an ffmpeg binary"))
    func remuxHEVC() async throws {
        let source = try Self.fixture("hevc_stream")
        let copy = try Self.extensionlessCopy(of: source)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try await Self.withRemuxer { cache in
            var config = MosaicConfiguration(width: 640, density: .xxl, format: .jpeg, includeMetadata: false)
            config.overlay.colorDNA = ColorDNAConfig(show: false)
            for url in [source, copy] {
                let video = try await VideoInput(from: url)
                #expect(video.url == url)
                #expect(video.width == 320 && video.height == 180)
                let duration = try #require(video.duration)
                #expect(abs(duration - 5.9) < 0.3, "duration \(duration)")
                let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
                #expect(image.width == 640)
            }
            // One file per source URL; a second inspection reuses it.
            #expect(try Self.cachedMP4s(cache).count == 2)
            let file = FFmpegCache.file(for: source, variant: "remux", extension: "mp4", in: cache)
            let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
            _ = try await VideoInput(from: source)
            let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
            #expect(before == after)

            try FFmpegFallback.clearCache()
            #expect(try Self.cachedMP4s(cache).isEmpty)
        }
    }

    @Test("A transport stream AVFoundation reads itself is not remuxed",
          .enabled(if: FFmpegFallback.isSupported && ffmpegPath != nil, "needs macOS and an ffmpeg binary"))
    func noRemuxForH264() async throws {
        try await Self.withRemuxer { cache in
            let video = try await VideoInput(from: Self.fixture("test_stream"))
            #expect(video.width == 320)
            #expect(try Self.cachedMP4s(cache).isEmpty)
        }
    }

    @Test("Concurrent readers of one source share a single remux",
          .enabled(if: FFmpegFallback.isSupported && ffmpegPath != nil, "needs macOS and an ffmpeg binary"))
    func concurrentRemux() async throws {
        let source = try Self.fixture("hevc_stream")
        try await Self.withRemuxer { cache in
            let files = try await withThrowingTaskGroup(of: URL.self) { group in
                for _ in 0..<4 {
                    group.addTask { try await RemoteVideoSupport.makeAsset(url: source).url }
                }
                return try await group.reduce(into: Set<URL>()) { $0.insert($1) }
            }
            #expect(files.count == 1)
            #expect(try Self.cachedMP4s(cache).count == 1)
        }
    }

    @Test("Enabling needs an executable ffmpeg")
    func enableValidates() {
        #expect(throws: MosaicError.self) {
            try FFmpegFallback.enable(ffmpegBinaryPath: "/nonexistent/ffmpeg")
        }
        #expect(!FFmpegFallback.isEnabled)
    }

    @Test("ffmpeg gets only the protocols its source needs")
    func inputProtocols() throws {
        #if os(macOS)
        let local = FFmpegRunner.inputArguments(for: URL(fileURLWithPath: "/v/a.ts"))
        #expect(local == ["-protocol_whitelist", "file", "-i", "file:/v/a.ts"])
        let remote = FFmpegRunner.inputArguments(for: URL(string: "https://h/download/?fid=1&s=2")!)
        #expect(remote == ["-protocol_whitelist", "http,https,tcp,tls,crypto", "-i", "https://h/download/?fid=1&s=2"])
        #endif
    }

    @Test("The cache evicts least recently used files past its size limit")
    func eviction() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitEvict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["old", "middle", "new"].enumerated() {
            let file = folder.appendingPathComponent("\(name).mp4")
            try Data(count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))],
                                                  ofItemAtPath: file.path)
        }
        // A remux in progress is never evicted.
        try Data(count: 100).write(to: folder.appendingPathComponent("running.part.mp4"))
        FFmpegCache.evict(in: folder, toFit: 150, maximumBytes: 300)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["new.mp4", "running.part.mp4"])
    }

    @Test("Cancelling one reader of a shared remux doesn't fail the others; the last cancel stops it")
    func sharedRemuxCancellation() async throws {
        let jobs = RemuxJobs()
        let source = URL(fileURLWithPath: "/v/shared.ts")
        let result = URL(fileURLWithPath: "/cache/shared.mp4")
        let workCancelled = Mutex(false)
        let work: @Sendable () async throws -> URL = {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { workCancelled.withLock { $0 = true }; throw error }
            return result
        }
        let cancelled = Task { try await jobs.result(for: source, work) }
        let kept = Task { try await jobs.result(for: source, work) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await kept.value == result)
        #expect(!workCancelled.withLock { $0 })

        let only = Task { try await jobs.result(for: source, work) }
        try await Task.sleep(for: .milliseconds(50))
        only.cancel()
        await #expect(throws: CancellationError.self) { try await only.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(workCancelled.withLock { $0 })
    }
}
