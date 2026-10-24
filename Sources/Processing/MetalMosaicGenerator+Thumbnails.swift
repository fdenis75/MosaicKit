import Foundation
import AVFoundation
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.mosaicKit", category: "thumbnail-extraction")

// MARK: - Thumbnail extraction

extension MetalMosaicGenerator {
    /// Extracts individual frames from a video, without building a mosaic.
    ///
    /// Frames are raw (no timestamp label), oriented as the video displays them, and scaled to fit
    /// `options.maximumSize`. The call is strict: if any frame cannot be decoded it throws. It
    /// runs off the generator actor, and `cancel(for:)`, `cancelAll()` and cancelling the calling
    /// task stop it with `CancellationError`. `options.format` and `options.compressionQuality`
    /// are ignored.
    ///
    /// All frames are held in memory at once; for many large frames prefer
    /// ``exportThumbnails(for:options:to:)``.
    /// - Parameters:
    ///   - video: The video to read.
    ///   - options: How many frames, at which size and times.
    /// - Returns: `options.count` thumbnails in temporal order.
    public func extractThumbnails(
        for video: VideoInput,
        options: ThumbnailExtractionOptions = ThumbnailExtractionOptions()
    ) async throws -> [VideoThumbnail] {
        try options.validateFrameSelection()
        return try await runTrackedThumbnailTask(for: video.id) {
            var thumbnails: [VideoThumbnail] = []
            thumbnails.reserveCapacity(options.count)
            try await Self.decodeThumbnails(of: video, options: options) { index, image, time in
                thumbnails.append(VideoThumbnail(index: index, time: time, image: image))
            }
            return thumbnails
        }
    }

    /// ``extractThumbnails(for:options:)`` returning only the images, in temporal order.
    public func extractThumbnailImages(
        for video: VideoInput,
        options: ThumbnailExtractionOptions = ThumbnailExtractionOptions()
    ) async throws -> [CGImage] {
        try await extractThumbnails(for: video, options: options).map(\.image)
    }

    /// Extracts individual frames from a video and writes each one to an image file.
    ///
    /// Each frame is encoded as soon as it is decoded, so only one frame is held in memory. Files
    /// are named `<video file name>_<number>.<extension>`, numbered from 1 in temporal order and
    /// zero-padded to at least four digits (`clip_0001.jpg`). A file of the same name in
    /// `directory` is replaced. If the export fails or is cancelled, the files it wrote are removed;
    /// so is the directory, when MosaicKit created it under the temporary directory or when a
    /// caller directory is left empty. Other files in a caller directory are never touched. Cancellation works as in
    /// ``extractThumbnails(for:options:)``.
    /// - Parameters:
    ///   - video: The video to read.
    ///   - options: How many frames, at which size and times, and the file format and quality.
    ///   - directory: Where to write the files; created if missing. `nil` creates a new directory
    ///     under `FileManager.default.temporaryDirectory/MosaicKitThumbnails/`, which the caller
    ///     owns and should remove when done.
    /// - Returns: The directory and the files written, in temporal order.
    public func exportThumbnails(
        for video: VideoInput,
        options: ThumbnailExtractionOptions = ThumbnailExtractionOptions(),
        to directory: URL? = nil
    ) async throws -> ThumbnailExport {
        try options.validate()
        return try await runTrackedThumbnailTask(for: video.id) {
            try await Self.writeThumbnails(of: video, options: options, to: directory)
        }
    }

    // MARK: Off-actor work

    /// Decodes the frames `options` selects and hands each one (index, image, decoded time in
    /// seconds) to `body`.
    @concurrent
    private nonisolated static func decodeThumbnails(
        of video: VideoInput,
        options: ThumbnailExtractionOptions,
        _ body: (Int, CGImage, TimeInterval) async throws -> Void
    ) async throws {
        // `VideoInput(from:)` releases its security-scoped grant when it returns; hold one for the
        // whole decode so a user-selected file stays readable in a sandboxed app.
        let didStartAccessingSource = video.url.startAccessingSecurityScopedResource()
        defer { if didStartAccessingSource { video.url.stopAccessingSecurityScopedResource() } }
        let asset = RemoteVideoSupport.makeAsset(url: video.url)
        let duration: Double
        if let known = video.duration { duration = known } else { duration = try await asset.load(.duration).seconds }
        guard duration.isFinite, duration > 0 else { throw MosaicError.invalidVideo("Invalid duration") }
        let policy: ThumbnailProcessor.FrameSamplingPolicy = options.sampling == .uniform ? .uniform : .weighted
        try await ThumbnailProcessor(config: .default).forEachFrame(
            from: asset, count: options.count, maximumSize: options.maximumSize,
            accurate: options.accurate, policy: policy, duration: duration
        ) { index, image, time in
            try await body(index, image, time.seconds)
        }
    }

    @concurrent
    private nonisolated static func writeThumbnails(
        of video: VideoInput,
        options: ThumbnailExtractionOptions,
        to requestedDirectory: URL?
    ) async throws -> ThumbnailExport {
        let fileManager = FileManager.default
        let directory = requestedDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("MosaicKitThumbnails", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let didStartAccessing = directory.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { directory.stopAccessingSecurityScopedResource() } }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = video.outputBaseName
        let digits = max(4, String(options.count).count)
        var files: [ThumbnailExport.File] = []
        files.reserveCapacity(options.count)
        do {
            try await decodeThumbnails(of: video, options: options) { index, image, time in
                let number = String(index + 1)
                let name = "\(baseName)_\(String(repeating: "0", count: max(0, digits - number.count)))\(number).\(options.format.fileExtension)"
                let url = directory.appendingPathComponent(name)
                let transaction = try OutputTransaction(finalURL: url, overwrite: true)
                defer { transaction.discard() }
                try ImageFileWriter.write(image, format: options.format, compressionQuality: options.compressionQuality,
                                          to: transaction.stagingURL, reportedURL: url)
                try transaction.commit()
                files.append(ThumbnailExport.File(index: index, time: time, url: url))
            }
        } catch {
            if requestedDirectory == nil {
                // The private UUID directory belongs to this attempt alone.
                try? fileManager.removeItem(at: directory)
            } else {
                // A caller directory may be shared with concurrent exports: remove only this
                // attempt's files, and the directory only if that leaves it empty.
                files.forEach { try? fileManager.removeItem(at: $0.url) }
                if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: directory)
                }
            }
            logger.error("Thumbnail export failed for \(video.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return ThumbnailExport(directory: directory, files: files)
    }
}
