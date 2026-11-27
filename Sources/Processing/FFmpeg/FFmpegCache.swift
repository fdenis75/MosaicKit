import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.mosaicKit", category: "ffmpeg-cache")

/// The folder of intermediate files (remuxes, seekable copies, player extracts), evicted least
/// recently used first.
enum FFmpegCache {
    /// The cache file of `source`: the first 16 hex digits of the SHA-256 of its URL (plus, for a
    /// local file, its size and modification date, so a file rewritten in place is redone) and
    /// of `variant`, which names how the file was made.
    static func file(for source: URL, variant: String, extension pathExtension: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data("\(key(for: source))#\(variant)".utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).\(pathExtension)")
    }

    /// Identifies a source and its current contents.
    static func key(for source: URL) -> String {
        var key = source.absoluteString
        if source.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) {
            let size = (attributes[.size] as? Int64) ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            key += "#\(size)#\(modified)"
        }
        return key
    }

    /// `file` if it exists, marked as just used.
    static func existing(_ file: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    /// The partial file a job writes before renaming it to `destination`.
    static func partial(of destination: URL) -> URL {
        destination.deletingPathExtension()
            .appendingPathExtension("part")
            .appendingPathExtension(destination.pathExtension)
    }

    /// The finished files in `directory`, oldest use first. Files being written are left out.
    static func files(in directory: URL) throws -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        return contents.filter {
            ["mp4", "mkv"].contains($0.pathExtension) && $0.deletingPathExtension().pathExtension != "part"
        }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.used < $1.used }
    }

    static func clear(_ directory: URL) throws {
        for file in try files(in: directory) {
            try FileManager.default.removeItem(at: file.url)
        }
    }

    /// Deletes the least recently used files until `incoming` more bytes fit in `maximumBytes`.
    static func evict(in directory: URL, toFit incoming: Int64, maximumBytes: Int64) {
        guard var files = try? files(in: directory) else { return }
        var total = files.reduce(0) { $0 + $1.size }
        while total + incoming > maximumBytes, !files.isEmpty {
            let oldest = files.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            logger.info("Evicted \(oldest.url.lastPathComponent, privacy: .public) from the ffmpeg cache")
        }
    }
}
