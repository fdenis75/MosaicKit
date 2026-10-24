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
enum RemoteVideoSupport {
    /// Path extensions AVFoundation recognizes on a network URL without a MIME override.
    static let recognizedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2", "mts", "m2ts", "ts", "m3u8"
    ]

    /// The MIME type `AVURLAsset` is told to assume for a source, or `nil` to let it decide.
    ///
    /// Local files are sniffed by AVFoundation, and a remote URL with a known video extension is
    /// parsed from that extension, so both get `nil`. Any other remote URL is read as MPEG-4
    /// (`video/mp4`), which the QuickTime parser also opens for `.mov` content.
    static func overrideMIMEType(for url: URL) -> String? {
        guard !url.isFileURL, !hasRecognizedExtension(url) else { return nil }
        return "video/mp4"
    }

    /// Creates the asset every reader of `url` uses, adding the MIME override when needed.
    static func makeAsset(url: URL, options: [String: Any] = [:]) -> AVURLAsset {
        var options = options
        if let mimeType = overrideMIMEType(for: url) {
            options[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        return AVURLAsset(url: url, options: options)
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
    /// signed link is refreshed.
    static func outputBaseName(url: URL, title: String) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != stem {
            return trimmedTitle
        }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let base = stem.isEmpty || stem == "/" ? "video" : stem
        return "\(base)-\(hash)"
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
