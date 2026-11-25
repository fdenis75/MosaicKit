import AVFoundation
import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.mosaicKit", category: "remote-video")

/// Support for sources that are not local files, such as `https` download links (I-30).
///
/// AVFoundation picks the container parser of a network URL from its path extension or the
/// server's `Content-Type`. A download link such as `https://host/download/?fid=…` served as
/// `application/octet-stream` has neither, so a plain `AVURLAsset` fails with "Cannot Open".
/// Such sources are identified from their first bytes by ``ContainerSniffer`` (I-38).
enum RemoteVideoSupport {
    /// Path extensions AVFoundation recognizes on a network URL without a MIME override.
    static let recognizedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2", "mts", "m2ts", "ts", "m3u8"
    ]

    /// The MIME type `AVURLAsset` is told to assume for a source, or `nil` to let it decide.
    ///
    /// A source with a known video extension is parsed from that extension, so it gets `nil` and
    /// is never read here. Any other source is identified from its first bytes (I-38): an MPEG
    /// transport stream gets `video/mp2t`, an MP4/QuickTime file `video/mp4`. When the bytes say
    /// neither, a remote URL is read as MPEG-4 (`video/mp4`, which the QuickTime parser also opens
    /// for `.mov` content, I-30) and a local file is left to AVFoundation, as before.
    static func overrideMIMEType(for url: URL) async -> String? {
        guard let container = await sourceContainer(for: url) else { return nil }
        return overrideMIMEType(for: url, container: container)
    }

    /// ``overrideMIMEType(for:)`` once the container of a source without a known extension is known.
    static func overrideMIMEType(for url: URL, container: ContainerSniffer.Container) -> String? {
        guard !hasRecognizedExtension(url) else { return nil }
        return container.mimeType ?? (url.isFileURL ? nil : "video/mp4")
    }

    /// The sniffed container of a source without a known video extension, or `nil` for one with
    /// such an extension (which is never read). Cached per URL by ``ContainerSniffer``.
    static func sourceContainer(for url: URL) async -> ContainerSniffer.Container? {
        guard !hasRecognizedExtension(url) else { return nil }
        return await ContainerSniffer.container(of: url)
    }

    /// Creates the asset every reader of `url` uses, adding the MIME override when needed.
    ///
    /// With `reduceReads`, an `http`/`https` source is read through a ``RangeRequestLoader``
    /// (small on-demand range requests) instead of AVFoundation's own loader. It changes nothing
    /// for a local file.
    static func makeAsset(url: URL, options: [String: Any] = [:], reduceReads: Bool = false) async -> AVURLAsset {
        let container = await sourceContainer(for: url)
        var options = options
        // The range loader needs the override too: AVFoundation picks the parser of an
        // extensionless URL before it asks the loader for the content type.
        if let container, let mimeType = overrideMIMEType(for: url, container: container) {
            options[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        if reduceReads, RangeRequestLoader.supports(url) {
            return RangeRequestLoader.makeAsset(url: url, options: options, container: container)
        }
        return AVURLAsset(url: url, options: options)
    }

    /// AVFoundation error codes meaning "this media can't be read" (not a cancel or network
    /// error): format not recognized, failed to parse, media cannot be used (-11869, HEVC/AV1 in
    /// TS), decoder not found, decode failed.
    static let unreadableMediaErrorCodes: Set<Int> = [-11828, -11829, -11869, -11833, -11821]

    /// Whether `error` is AVFoundation refusing the media itself, so it may be reported as
    /// ``unreadableTransportStreamError(for:)``. Cancellation and network errors are not.
    static func isUnreadableMediaError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == AVFoundationErrorDomain && unreadableMediaErrorCodes.contains(error.code)
    }

    /// Path extensions of MPEG transport streams.
    static let transportStreamExtensions: Set<String> = ["ts", "m2ts", "mts"]

    /// What AVFoundation can't read from an MPEG transport stream on this platform (I-38): on
    /// macOS its TS demuxer reads H.264 and MPEG-2 video only; on iOS (measured on the iOS
    /// Simulator in CI) it opens no standalone transport stream at all.
    #if os(macOS)
    static let unreadableTransportStreamDescription =
        "an MPEG transport stream whose video isn't H.264 or MPEG-2 (HEVC and AV1 in TS can't be read)"
    #else
    static let unreadableTransportStreamDescription =
        "an MPEG transport stream (.ts), a container this platform can't read"
    #endif

    /// The error for a source AVFoundation opened but can't read video from, when that source
    /// is an MPEG transport stream: on macOS HEVC or AV1 in TS gives "Cannot Open" and MPEG-4
    /// Part 2 no video track; on iOS every TS fails (I-38). `nil` for other sources, whose
    /// original error is kept.
    static func unreadableTransportStreamError(for url: URL) async -> VideoError? {
        let isTransportStream = transportStreamExtensions.contains(url.pathExtension.lowercased())
        if !isTransportStream {
            guard await sourceContainer(for: url) == .transportStream else { return nil }
        }
        return .unsupportedCodec(url, unreadableTransportStreamDescription)
    }

    /// Whether `url`'s path ends in an extension from ``recognizedExtensions``.
    static func hasRecognizedExtension(_ url: URL) -> Bool {
        recognizedExtensions.contains(url.pathExtension.lowercased())
    }

    /// The base name for outputs of a remote source whose path has no video extension.
    ///
    /// The URL's last path component ("download") is shared by every link of such a service, so
    /// it gets the first 8 hex digits of the SHA-256 of the full URL. A caller-supplied `title`
    /// (one that differs from that component) is used instead, so names stay stable when a
    /// signed link is refreshed. The title is reduced to one file-name component (see
    /// ``fileNameComponent(_:)``), because thumbnail export appends it to a directory as is.
    static func outputBaseName(url: URL, title: String) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != stem {
            let component = fileNameComponent(trimmedTitle)
            if !component.isEmpty { return component }
        }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let base = stem.isEmpty || stem == "/" ? "video" : stem
        return "\(base)-\(hash)"
    }

    /// `name` as a single path component: path separators become `_` and leading dots are
    /// dropped, so `../outside` gives `.._outside` → `_outside` and can't leave the directory.
    static func fileNameComponent(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:")
        let joined = name.components(separatedBy: separators).joined(separator: "_")
        return String(joined.drop(while: { $0 == "." }))
    }

    /// The total size of an `http`/`https` resource, from a one-byte range request.
    ///
    /// Best effort: returns `nil` on any network error, an error status or a response without a
    /// size. The body is never downloaded: the request is cancelled once the headers arrive.
    static func contentLength(of url: URL) async -> Int64? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return nil }
            return totalLength(statusCode: http.statusCode,
                               contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                               expectedContentLength: http.expectedContentLength)
        } catch {
            logger.debug("Size probe failed for \(url.host() ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The resource size a range-request response reports: the total of `Content-Range` for a
    /// 206, `Content-Length` for a 200 (a server that ignored the range), `nil` otherwise.
    static func totalLength(statusCode: Int, contentRange: String?, expectedContentLength: Int64) -> Int64? {
        switch statusCode {
        case 206:
            guard let total = contentRange?.split(separator: "/").last,
                  let size = Int64(total.trimmingCharacters(in: .whitespaces)), size > 0 else { return nil }
            return size
        case 200:
            return expectedContentLength > 0 ? expectedContentLength : nil
        default:
            return nil
        }
    }
}

extension VideoInput {
    /// The source name that output file names are built from.
    ///
    /// For a local file, and for a remote URL whose path has a video extension, this is the file
    /// name without its extension, as before. A remote URL without one (a download link such as
    /// `https://host/download/?fid=…`) would give every video the same name, so it uses
    /// ``title`` when you supplied one, otherwise the last path component plus 8 hex digits of
    /// the URL's SHA-256 (I-30). Pass a `title` (or a `postID`) for names that survive a
    /// refreshed signed link.
    public var outputBaseName: String {
        if url.isFileURL || RemoteVideoSupport.hasRecognizedExtension(url) {
            return url.deletingPathExtension().lastPathComponent
        }
        return RemoteVideoSupport.outputBaseName(url: url, title: title)
    }
}
