import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MosaicKit

/// Serves the embedded `test_video.mp4` for any `https` URL, honoring `Range` headers, and counts
/// the body bytes it returns. Host `norange.test` ignores ranges and always sends the whole file;
/// host `ts.test` serves `test_stream.ts` (an MPEG transport stream) as `binary/octet-stream`.
/// No network I/O: the URLs are synthetic and never leave the process.
final class FixtureRangeURLProtocol: URLProtocol, @unchecked Sendable {
    static let servedBytes = Mutex<Int64>(0)
    static let requests = Mutex<Int>(0)
    static let fixture: Data = {
        guard let url = Bundle.module.url(forResource: "test_video", withExtension: "mp4"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()
    static let transportStream: Data = {
        guard let url = Bundle.module.url(forResource: "test_stream", withExtension: "ts"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureRangeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let isTransportStream = url.host() == "ts.test"
        let data = isTransportStream ? Self.transportStream : Self.fixture
        let total = data.count
        var status = 200
        var body = data
        var headers = ["Content-Type": isTransportStream ? "binary/octet-stream" : "video/mp4", "Accept-Ranges": "bytes"]
        if url.host() != "norange.test", let range = request.value(forHTTPHeaderField: "Range"),
           let match = range.firstMatch(of: /bytes=(\d+)-(\d*)/) {
            let start = Int(match.1) ?? 0
            let end = min(Int(match.2) ?? (total - 1), total - 1)
            body = data.subdata(in: start..<(end + 1))
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }
        headers["Content-Length"] = String(body.count)
        Self.servedBytes.withLock { $0 += Int64(body.count) }
        Self.requests.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("reduceSourceReads", .serialized)
struct ReduceSourceReadsTests {
    private static let fixtureURL = Bundle.module.url(forResource: "test_video", withExtension: "mp4")

    // MARK: Configuration

    @Test("reduceSourceReads defaults to off, also for configurations saved without the key")
    func defaultsAndDecoding() throws {
        #expect(MosaicConfiguration().reduceSourceReads == false)
        var config = MosaicConfiguration()
        config.reduceSourceReads = true
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(MosaicConfiguration.self, from: data).reduceSourceReads)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "reduceSourceReads")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(MosaicConfiguration.self, from: legacy).reduceSourceReads == false)
    }

    @Test("reduceSourceReads can't be combined with accurate timestamps")
    func validationRejectsAccurateTimestamps() throws {
        var config = MosaicConfiguration()
        config.reduceSourceReads = true
        try config.validate()
        config.useAccurateTimestamps = true
        #expect(throws: MosaicError.self) { try config.validate() }
    }

    @Test("reduceSourceReads doesn't change where outputs land")
    func outputIdentityUnchanged() {
        var config = MosaicConfiguration()
        let before = config.configurationHash
        config.reduceSourceReads = true
        #expect(config.configurationHash == before)
    }

    @Test("minimal() drops every metadata-derived drawing and nothing else")
    func minimalConfiguration() {
        var config = MosaicConfiguration()
        config.overlay.colorDNA.show = true
        let minimal = config.minimal()
        #expect(minimal.includeMetadata == false)
        #expect(minimal.useMovieColorsForBg == false)
        #expect(minimal.overlay.colorDNA.show == false)
        #expect(minimal.width == config.width && minimal.density == config.density)
    }

    // MARK: Time tolerance

    @Test("Keyframe snapping wins over the default tolerance")
    func timeTolerance() throws {
        let url = try #require(Self.fixtureURL)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        ThumbnailProcessor.applyTimeTolerance(to: generator, accurate: false, snapToKeyframes: false)
        #expect(generator.requestedTimeToleranceBefore == CMTime(seconds: 1, preferredTimescale: 600))
        ThumbnailProcessor.applyTimeTolerance(to: generator, accurate: true, snapToKeyframes: false)
        #expect(generator.requestedTimeToleranceAfter == .zero)
        ThumbnailProcessor.applyTimeTolerance(to: generator, accurate: false, snapToKeyframes: true)
        #expect(generator.requestedTimeToleranceBefore == .positiveInfinity)
        #expect(generator.requestedTimeToleranceAfter == .positiveInfinity)
    }

    // MARK: Loader

    @Test("Only http and https sources go through the range loader")
    func loaderScope() async throws {
        let local = try #require(Self.fixtureURL)
        #expect(RangeRequestLoader.supports(URL(string: "https://host/video.mp4")!))
        #expect(RangeRequestLoader.supports(URL(string: "http://host/video")!))
        #expect(!RangeRequestLoader.supports(local))
        #expect(!RangeRequestLoader.supports(URL(string: "https://host/live/index.m3u8")!))
        #expect(await RemoteVideoSupport.makeAsset(url: local, reduceReads: true).url == local)
        let remote = await RemoteVideoSupport.makeAsset(url: URL(string: "https://host/dl.mp4?fid=1")!, reduceReads: true)
        #expect(remote.url.absoluteString == "mosaickit-https://host/dl.mp4?fid=1")
    }

    @Test("The parser type comes from the extension, then the MIME type, else MPEG-4")
    func contentType() {
        #expect(RangeRequestLoader.uti(for: URL(string: "https://h/a.mov")!, mimeType: nil) == "com.apple.quicktime-movie")
        #expect(RangeRequestLoader.uti(for: URL(string: "https://h/dl")!, mimeType: "video/quicktime") == "com.apple.quicktime-movie")
        #expect(RangeRequestLoader.uti(for: URL(string: "https://h/dl")!, mimeType: "application/octet-stream") == "public.mpeg-4")
        // I-38: a sniffed container wins over the server's MIME type, not over the extension.
        #expect(RangeRequestLoader.uti(for: URL(string: "https://h/dl")!, mimeType: "application/octet-stream",
                                       container: .transportStream) == "public.mpeg-2-transport-stream")
        #expect(RangeRequestLoader.uti(for: URL(string: "https://h/a.mov")!, mimeType: nil,
                                       container: .transportStream) == "com.apple.quicktime-movie")
    }

    @Test("An extensionless transport stream reads through the range loader (I-38)")
    func loaderReadsTransportStream() async throws {
        let session = FixtureRangeURLProtocol.session()
        let url = URL(string: "https://ts.test/download/?fid=1")!
        #expect(await ContainerSniffer.leadingBytes(of: url, session: session).map(ContainerSniffer.container(of:)) == .transportStream)
        let asset = RangeRequestLoader.makeAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp2t"],
                                                 container: .transportStream, session: session)
        let frames = try await ThumbnailProcessor(config: .default).extractFrames(
            from: asset, count: 3, maximumSize: CGSize(width: 160, height: 90),
            accurate: false, snapToKeyframes: true, policy: .uniform)
        #expect(frames.count == 3)
    }

    @Test("Frames read through the range loader match the local file and read part of it")
    func loaderDecodesSameFrames() async throws {
        let local = try #require(Self.fixtureURL)
        let session = FixtureRangeURLProtocol.session()
        FixtureRangeURLProtocol.servedBytes.withLock { $0 = 0 }
        let remote = RangeRequestLoader.makeAsset(url: URL(string: "https://fixture.test/test_video.mp4")!,
                                                  options: [:], session: session)
        let processor = ThumbnailProcessor(config: .default)
        func colors(_ asset: AVAsset) async throws -> [(CGFloat, CGFloat, CGFloat)] {
            try await processor.extractFrames(from: asset, count: 6, maximumSize: CGSize(width: 160, height: 90),
                                              accurate: false, snapToKeyframes: true, policy: .uniform)
                .map { frame in
                    let components = OverlayProcessor.averageColor(of: frame.image).components ?? [0, 0, 0]
                    return (components[0], components[1], components[2])
                }
        }
        let remoteColors = try await colors(remote)
        let localColors = try await colors(AVURLAsset(url: local))
        #expect(remoteColors.count == 6)
        for (a, b) in zip(remoteColors, localColors) {
            #expect(abs(a.0 - b.0) < 0.02 && abs(a.1 - b.1) < 0.02 && abs(a.2 - b.2) < 0.02)
        }
        let served = FixtureRangeURLProtocol.servedBytes.withLock { $0 }
        #expect(served < Int64(FixtureRangeURLProtocol.fixture.count) / 2, "served \(served) bytes")
    }

    @Test("A fetch returns exactly the requested bytes, and a server that ignores ranges is refused")
    func fetchHonorsRange() async throws {
        let session = FixtureRangeURLProtocol.session()
        let ranged = RangeRequestLoader(sourceURL: URL(string: "https://fixture.test/test_video.mp4")!, session: session)
        let (data, info) = try await ranged.fetch(4...7)
        #expect(data == FixtureRangeURLProtocol.fixture.subdata(in: 4..<8))
        #expect(info.length == Int64(FixtureRangeURLProtocol.fixture.count))
        #expect(info.uti == "public.mpeg-4")

        let ignoring = RangeRequestLoader(sourceURL: URL(string: "https://norange.test/test_video.mp4")!, session: session)
        await #expect(throws: MosaicError.self) { _ = try await ignoring.fetch(0...1) }
    }

    @Test("A server that ignores byte ranges fails the read with a clear error")
    func serverWithoutRanges() async throws {
        let asset = RangeRequestLoader.makeAsset(url: URL(string: "https://norange.test/test_video.mp4")!,
                                                 options: [:], session: FixtureRangeURLProtocol.session())
        await #expect(throws: (any Error).self) {
            _ = try await ThumbnailProcessor(config: .default).extractFrames(
                from: asset, count: 2, maximumSize: CGSize(width: 64, height: 36),
                accurate: false, snapToKeyframes: true, policy: .uniform)
        }
    }
}
