import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "com.mosaicKit", category: "container-sniffer")

/// Identifies the container of a source whose path extension doesn't, from its first bytes (I-38).
///
/// AVFoundation picks the parser of an extensionless source from the MIME type it is given, and
/// I-30 assumed MPEG-4 for every remote one. An MPEG transport stream behind a download link (and
/// an extensionless local `.ts` file, which AVFoundation doesn't sniff either) then failed with
/// "Cannot Open", although AVFoundation reads H.264 and MPEG-2 video from TS.
enum ContainerSniffer {
    /// What the leading bytes say about a source.
    enum Container: Sendable, Equatable {
        /// An ISO base media file (MP4, M4V, QuickTime `.mov`).
        case mpeg4
        /// An MPEG-2 transport stream: 188-byte packets, or 192-byte M2TS (Blu-ray / AVCHD) ones.
        case transportStream
        /// Neither; or the bytes couldn't be read.
        case unknown

        /// The MIME type that makes `AVURLAsset` parse this container, if one is known.
        var mimeType: String? {
            switch self {
            case .mpeg4: return "video/mp4"
            case .transportStream: return "video/mp2t"
            case .unknown: return nil
            }
        }

        /// The uniform type identifier a resource loader reports for this container, if known.
        /// `UTType(mimeType: "video/mp2t")` gives a dynamic type, so the identifier is spelled out.
        var uti: String? {
            switch self {
            case .mpeg4: return "public.mpeg-4"
            case .transportStream: return "public.mpeg-2-transport-stream"
            case .unknown: return nil
            }
        }
    }

    /// Bytes read from the start of a source: enough for five 192-byte M2TS packets.
    static let byteCount = 1024

    /// ISO base media box types that can open a file: `ftyp` in MP4, the others in old QuickTime.
    private static let leadingBoxTypes: Set<String> = ["ftyp", "moov", "mdat", "free", "wide", "skip", "pnot"]

    /// The container `bytes` (the start of a source) belong to.
    ///
    /// A transport stream needs the `0x47` sync byte at the start of every whole packet in `bytes`,
    /// and at least two packets: one sync byte alone matches 1 random file in 256.
    static func container(of bytes: Data) -> Container {
        let bytes = [UInt8](bytes.prefix(byteCount))
        if bytes.count >= 8, let type = String(bytes: bytes[4..<8], encoding: .ascii), leadingBoxTypes.contains(type) {
            return .mpeg4
        }
        if hasSyncBytes(bytes, offset: 0, packetSize: 188) || hasSyncBytes(bytes, offset: 4, packetSize: 192) {
            return .transportStream
        }
        return .unknown
    }

    private static func hasSyncBytes(_ bytes: [UInt8], offset: Int, packetSize: Int) -> Bool {
        let positions = Array(stride(from: offset, to: bytes.count, by: packetSize))
        return positions.count >= 2 && positions.allSatisfy { bytes[$0] == 0x47 }
    }

    // MARK: Reading sources

    /// The most sources whose container is remembered; the cache is emptied when it is full.
    static let cacheLimit = 1024
    private static let cache = Mutex<[URL: Container]>([:])

    /// The container of `url`, read once and then remembered for the process.
    ///
    /// Reads ``byteCount`` bytes: from the file, or with one range request for `http`/`https`.
    /// Returns ``Container/unknown`` when the bytes can't be read; the caller keeps its default.
    /// Only a successful read is cached, so a cancelled or failed sniff is retried next time.
    static func container(of url: URL, session: URLSession = .shared) async -> Container {
        if let known = cache.withLock({ $0[url] }) { return known }
        guard let bytes = await leadingBytes(of: url, session: session) else { return .unknown }
        let container = Self.container(of: bytes)
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll() }
            cache[url] = container
        }
        return container
    }

    /// The first ``byteCount`` bytes of `url`, or `nil` when they can't be read.
    static func leadingBytes(of url: URL, session: URLSession = .shared) async -> Data? {
        if url.isFileURL {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: byteCount)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-\(byteCount - 1)", forHTTPHeaderField: "Range")
        do {
            // Streamed and cancelled after `byteCount` bytes: a server that ignores the range
            // answers 200 with the whole file.
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 else {
                return nil
            }
            var data = Data()
            data.reserveCapacity(byteCount)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= byteCount { break }
            }
            return data
        } catch {
            logger.debug("Container sniff failed for \(url.host() ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
