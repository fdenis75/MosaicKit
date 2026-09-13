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
            // link is atomic and fails if another attempt has already published the path.
            let result = stagingURL.withUnsafeFileSystemRepresentation { source in
                finalURL.withUnsafeFileSystemRepresentation { destination in
                    Darwin.link(source, destination)
                }
            }
            guard result == 0 else {
                if errno == EEXIST { throw MosaicError.fileExists(finalURL) }
                throw MosaicError.processingFailed("Output publication failed (errno \(errno))")
            }
            discard()
        }
    }
}
