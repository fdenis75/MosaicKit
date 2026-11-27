#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO

/// Frames of a source only ffmpeg decodes, by seeking to each time: nothing between two frames
/// is read.
enum FFmpegFrames {
    private static let inputsPerProcess = 10
    private static let concurrentProcesses = 4

    /// Decodes one frame at each of `times` and hands each (position in `times`, image) to
    /// `body`, in order. Strict, like the native path: a frame that can't be decoded throws.
    ///
    /// - Parameters:
    ///   - box: The size the frame must fit inside (never enlarged); `nil` keeps the display size.
    static func forEach(
        in source: FFmpegSource,
        at times: [TimeInterval],
        fitting box: CGSize?,
        _ body: (Int, CGImage) async throws -> Void
    ) async throws {
        let starts = Array(stride(from: 0, to: times.count, by: inputsPerProcess))
        try await withThrowingTaskGroup(of: (Int, [CGImage]).self) { group in
            var finished: [Int: [CGImage]] = [:]
            var launched = 0
            var delivered = 0
            while delivered < starts.count {
                // Bounded both ways: processes at once, and batches waiting for an earlier one.
                while launched < starts.count, launched - delivered < concurrentProcesses * 2,
                      launched - delivered - finished.count < concurrentProcesses {
                    let batch = launched
                    let slice = Array(times[starts[batch]..<min(starts[batch] + inputsPerProcess, times.count)])
                    group.addTask { (batch, try await decode(source, at: slice, fitting: box)) }
                    launched += 1
                }
                guard let (batch, images) = try await group.next() else { break }
                finished[batch] = images
                while let images = finished.removeValue(forKey: delivered) {
                    for (offset, image) in images.enumerated() {
                        try Task.checkCancellation()
                        try await body(starts[delivered] + offset, image)
                    }
                    delivered += 1
                }
            }
        }
    }

    /// The frames at `times`, one ffmpeg process.
    private static func decode(_ source: FFmpegSource, at times: [TimeInterval], fitting box: CGSize?) async throws -> [CGImage] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mk-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var images = try await run(source, at: times, fitting: box, in: folder, prefix: "a")
        // A container's duration can overshoot the last frame: one retry, slightly earlier.
        for index in images.indices where images[index] == nil {
            guard times[index] > source.info.duration * 0.8 else { continue }
            let earlier = max(times[index] - 2, 0)
            images[index] = try await run(source, at: [earlier], fitting: box, in: folder, prefix: "r\(index)-")[0]
        }
        return try images.enumerated().map { index, image in
            guard let image else {
                throw MosaicError.processingFailed("Frame extraction failed at \(String(format: "%.2f", times[index])) s")
            }
            return image
        }
    }

    private static func run(_ source: FFmpegSource, at times: [TimeInterval], fitting box: CGSize?,
                            in folder: URL, prefix: String) async throws -> [CGImage?] {
        var arguments = ["-nostdin", "-hide_banner", "-v", "error", "-y"]
        for time in times {
            arguments += ["-ss", String(format: "%.3f", time)] + FFmpegRunner.inputArguments(for: source.input)
        }
        var filters: [String] = []
        if source.info.isInterlaced { filters.append("yadif=mode=send_frame") }
        // Square pixels, as AVFoundation delivers them.
        filters.append("scale=trunc(iw*sar):ih,setsar=1")
        if let box {
            let width = max(Int(box.width.rounded()), 2)
            let height = max(Int(box.height.rounded()), 2)
            filters.append("scale='min(\(width),iw)':'min(\(height),ih)':force_original_aspect_ratio=decrease")
        }
        let outputs = times.indices.map { folder.appendingPathComponent("\(prefix)\($0).bmp") }
        for (index, output) in outputs.enumerated() {
            // `V` leaves cover art out.
            arguments += ["-map", "\(index):V:0", "-frames:v", "1", "-vf", filters.joined(separator: ","),
                          "-c:v", "bmp", "-pix_fmt", "bgr24", "-f", "image2", "-update", "1", output.path]
        }
        let result = try await FFmpegRunner.run(source.settings.ffmpegBinaryPath, arguments,
                                                timeout: 60 + 30 * Double(times.count))
        let images = outputs.map(load)
        if images.allSatisfy({ $0 == nil }), result.status != 0 {
            // Said once here: the retry or the caller's error names only the time.
            if times.count > 1 || times[0] < source.info.duration * 0.8 {
                throw MosaicError.processingFailed("Frame extraction failed: \(result.stderr.suffix(300))")
            }
        }
        return images
    }

    /// Reads the whole file first: the folder is deleted before the image is drawn.
    private static func load(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
#endif
