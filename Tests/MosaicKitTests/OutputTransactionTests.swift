import Foundation
import Testing
@testable import MosaicKit

/// Verifies `OutputTransaction`'s non-overwrite publish path, which claims the
/// final path with an exclusive create (`fopen(..., "wx")`) followed by
/// `rename(2)` rather than `link(2)`. `link(2)` returns ENOTSUP on network
/// filesystems such as SMB, which broke publication even when no colliding
/// file existed.
struct OutputTransactionTests {
    @Test func commitWithoutOverwritePublishesWhenPathIsFree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let finalURL = directory.appendingPathComponent("output.txt")
        let transaction = try OutputTransaction(finalURL: finalURL, overwrite: false)
        try Data("payload".utf8).write(to: transaction.stagingURL)

        try transaction.commit()

        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: transaction.stagingURL.path))
    }

    @Test func commitWithoutOverwriteThrowsFileExistsWhenAlreadyPublished() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let finalURL = directory.appendingPathComponent("output.txt")
        try Data("already-published".utf8).write(to: finalURL)

        let transaction = try OutputTransaction(finalURL: finalURL, overwrite: false)
        try Data("payload".utf8).write(to: transaction.stagingURL)

        #expect(throws: MosaicError.self) {
            try transaction.commit()
        }
    }
}
