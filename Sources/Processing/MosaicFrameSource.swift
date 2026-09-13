import Foundation
import AVFoundation
import CoreGraphics

/// Pull ownership means decoding cannot outrun the compositor. There is no producer task
/// or dropping buffer; one requested image is owned by each next() invocation.
internal actor MosaicFrameSource {
    private let generator: MosaicImageDecoder
    private let count: Int
    private let makeTimes: @Sendable (Double) -> [CMTime]
    private let timestamp: @Sendable (Double) -> String
    private var times: [CMTime]?
    private var index = 0
    private var requesting = false

    internal init(decoder: MosaicImageDecoder, count: Int,
                  times: @escaping @Sendable (Double) -> [CMTime],
                  timestamp: @escaping @Sendable (Double) -> String) {
        self.generator = decoder
        self.count = count
        self.makeTimes = times
        self.timestamp = timestamp
    }

    internal func next() async throws -> (index: Int, image: CGImage, timestamp: String)? {
        try Task.checkCancellation()
        guard !requesting else { throw MosaicError.processingFailed("Frame stream requires a single consumer") }
        requesting = true
        defer { requesting = false }
        if times == nil {
            let duration = try await generator.duration()
            guard duration.isFinite, duration > 0, count > 0, count <= 100_000 else {
                throw MosaicError.invalidVideo("Invalid extraction duration or frame count")
            }
            let requestedTimes = makeTimes(duration)
            guard requestedTimes.count == count else { throw MosaicError.processingFailed("Invalid extraction plan") }
            times = requestedTimes
        }
        guard let times, index < times.count else { return nil }
        let frameIndex = index
        let time = times[frameIndex]
        // Reserve the index before suspension; a sequence is normally single-consumer.
        index += 1
        let generator = self.generator
        return try await withTaskCancellationHandler {
            var lastError: (any Error)?
            for _ in 0..<2 {
                try Task.checkCancellation()
                do {
                    let result = try await generator.image(at: time)
                    try Task.checkCancellation()
                    return (frameIndex, result.image, timestamp(result.actualTime.seconds))
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                }
            }
            throw MosaicError.processingFailed("Frame \(frameIndex) failed after retry: \(lastError?.localizedDescription ?? "unknown")")
        } onCancel: { generator.cancel() }
    }
}

/// AVAssetImageGenerator is configured before transfer and never mutated afterward.
/// The owning source permits only one image request at a time. AVFoundation's
/// cancelAllCGImageGeneration is the sole concurrent operation, specifically designed
/// to cancel a pending asynchronous request from its cancellation handler.
internal final class MosaicImageDecoder: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let asset: AVAsset
    internal init(asset: AVAsset, generator: AVAssetImageGenerator) { self.asset = asset; self.generator = generator }
    internal func duration() async throws -> Double { try await asset.load(.duration).seconds }
    internal func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try await generator.image(at: time)
    }
    internal func cancel() { generator.cancelAllCGImageGeneration() }
}
