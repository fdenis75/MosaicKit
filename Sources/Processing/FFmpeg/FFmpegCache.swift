import CryptoKit
import Foundation
import ObjectiveC
import OSLog
import Synchronization

private let logger = Logger(subsystem: "com.mosaicKit", category: "ffmpeg-cache")

/// The folder of intermediate files (remuxes, seekable copies, player extracts), evicted least
/// recently used first.
enum FFmpegCache {
    /// How many readers hold each file, by resolved path. Eviction leaves held files alone.
    private static let held = Mutex<[String: Int]>([:])

    /// Keeps a file from eviction for as long as the lease is alive (this process only).
    final class Lease: Sendable {
        private let path: String

        init(_ file: URL) {
            let path = file.resolvingSymlinksInPath().path
            self.path = path
            FFmpegCache.held.withLock { $0[path, default: 0] += 1 }
        }

        deinit {
            let path = self.path
            FFmpegCache.held.withLock {
                $0[path, default: 1] -= 1
                if $0[path] == 0 { $0[path] = nil }
            }
        }
    }

    /// Holds `file` for as long as `owner` (the asset or composition reading it) is alive.
    static func hold(_ file: URL, for owner: AnyObject) {
        let lease = Lease(file)
        // Each lease is its own key, so one owner can hold several files.
        objc_setAssociatedObject(owner, Unmanaged.passUnretained(lease).toOpaque(), lease, .OBJC_ASSOCIATION_RETAIN)
    }

    static func isHeld(_ file: URL) -> Bool {
        let path = file.resolvingSymlinksInPath().path
        return held.withLock { $0[path] != nil }
    }

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

    /// A partial file for one job to write before ``publish(_:as:)``. Unique per call, so two
    /// jobs making the same file never write or delete each other's.
    static func partial(of destination: URL) -> URL {
        destination.deletingPathExtension()
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("part")
            .appendingPathExtension(destination.pathExtension)
    }

    /// Renames `partial` to `destination`. Another job having made it first is success.
    static func publish(_ partial: URL, as destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
        }
    }

    /// Whether `url` has a name this cache gives: nothing else in the folder is ever deleted.
    private static func isCacheFile(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        return ["mp4", "mkv"].contains(url.pathExtension) && stem.count == 16 && stem.allSatisfy(\.isHexDigit)
    }

    /// The finished files in `directory`, oldest use first. Files being written are left out.
    static func files(in directory: URL) throws -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        return contents.filter(isCacheFile).compactMap { url in
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
    /// Files being read are skipped, so the cache can stay over its limit while they are.
    static func evict(in directory: URL, toFit incoming: Int64, maximumBytes: Int64) {
        guard var files = try? files(in: directory) else { return }
        var total = files.reduce(0) { $0 + $1.size }
        while total + incoming > maximumBytes, !files.isEmpty {
            let oldest = files.removeFirst()
            if isHeld(oldest.url) { continue }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            logger.info("Evicted \(oldest.url.lastPathComponent, privacy: .public) from the ffmpeg cache")
        }
    }
}
