import Foundation
import Darwin

/// An attempt-owned staging file. Publish only after the encoder has finalized it.
internal struct OutputTransaction: Sendable {
    internal let finalURL: URL
    internal let stagingURL: URL
    private let overwrite: Bool

    internal init(finalURL: URL, overwrite: Bool = true) throws {
        self.finalURL = finalURL
        self.overwrite = overwrite
        let directory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stagingURL = directory.appendingPathComponent(".mosaickit-\(UUID().uuidString).\(finalURL.pathExtension)")
    }

    internal func discard() {
        try? FileManager.default.removeItem(at: stagingURL)
    }

    internal func commit() throws {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
            throw MosaicError.processingFailed("Encoder produced an empty output")
        }
        if overwrite {
            let result = stagingURL.withUnsafeFileSystemRepresentation { source in
                finalURL.withUnsafeFileSystemRepresentation { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else {
                throw MosaicError.processingFailed("Atomic output publication failed (errno \(errno))")
            }
        } else {
            // O_CREAT | O_EXCL atomically claims the final path and fails if another
            // attempt has already published it. Unlike link(2), this is supported by
            // network filesystems such as SMB (link(2) returns ENOTSUP there).
            // fopen's C11 "x" mode maps to O_EXCL; Darwin.open is unavailable to Swift
            // (its variadic mode parameter can't be called), so this is the accessible
            // equivalent for an exclusive create.
            let file = finalURL.withUnsafeFileSystemRepresentation { destination in
                Darwin.fopen(destination, "wx")
            }
            guard let file else {
                if errno == EEXIST { throw MosaicError.fileExists(finalURL) }
                throw MosaicError.processingFailed("Output publication failed (errno \(errno))")
            }
            Darwin.fclose(file)
            let result = stagingURL.withUnsafeFileSystemRepresentation { source in
                finalURL.withUnsafeFileSystemRepresentation { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else {
                throw MosaicError.processingFailed("Atomic output publication failed (errno \(errno))")
            }
        }
    }
}
