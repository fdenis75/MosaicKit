import AVFoundation
import Foundation
import ObjectiveC
import OSLog
import Synchronization
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.mosaicKit", category: "range-loader")

/// Serves an `http`/`https` source to AVFoundation with small byte-range requests made only on
/// demand, for ``MosaicConfiguration/reduceSourceReads``.
///
/// AVFoundation's own HTTP loader answers every seek with an open-ended `Range: bytes=N-` request
/// and cancels it once it has what it needs, by which point about 0.5 MB has arrived. That's
/// three times a 1080p keyframe. This loader fetches ``initialChunk`` bytes, then ``followingChunk``
/// bytes at a time, and starts the next fetch only while AVFoundation still waits for data, so a
/// seek costs about what the decoder consumes plus the one fetch in flight when it cancels.
/// Measured on a 10-minute 1080p source: 35 MB → ~15–20 MB per mosaic, for more requests.
final class RangeRequestLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    /// Bytes of the first fetch of a loading request: about one 1080p keyframe.
    static let initialChunk = 192 * 1024
    /// Bytes of every later fetch of the same loading request.
    static let followingChunk = 64 * 1024
    /// The most bytes one loading request is served before it is finished. AVFoundation asks for
    /// large ranges (often to the end of the file) and doesn't always cancel them (it keeps
    /// reading ahead after the last frame it wanted); when it needs more, it opens a new loading
    /// request. Frame extraction handles this (verified up to 2.9 MB 4K keyframes); a preview
    /// export doesn't, which is one reason previews don't use this loader.
    static let maximumBytesPerRequest: Int64 = 1024 * 1024
    /// The prefix of the private scheme AVFoundation sees (`mosaickit-https`), so it calls the
    /// delegate instead of loading the URL itself.
    static let schemePrefix = "mosaickit-"

    /// The source's total size and type, read from the first response and reused afterwards.
    struct ContentInfo: Sendable {
        let length: Int64
        let uti: String
    }

    /// A loading request handed to a fetch task. AVFoundation's loading requests aren't
    /// `Sendable`; every call on one is made on ``queue``, the queue the delegate runs on.
    private struct RequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
    }

    let sourceURL: URL
    let queue = DispatchQueue(label: "com.mosaicKit.range-loader")
    private let session: URLSession
    private let info = Mutex<ContentInfo?>(nil)
    private let tasks = Mutex<[ObjectIdentifier: Task<Void, Never>]>([:])

    init(sourceURL: URL, session: URLSession = .shared) {
        self.sourceURL = sourceURL
        self.session = session
    }

    /// The URL to give `AVURLAsset`: `sourceURL` with ``schemePrefix`` before its scheme.
    var assetURL: URL {
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        components?.scheme = Self.schemePrefix + (sourceURL.scheme ?? "https")
        return components?.url ?? sourceURL
    }

    /// Whether `url` can be served by this loader: `http` or `https`, and not an HLS playlist,
    /// whose variant playlists and segments are other URLs this loader doesn't fetch.
    static func supports(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !["m3u8", "m3u"].contains(url.pathExtension.lowercased())
    }

    /// An asset of `url` that reads through a new loader. The asset keeps the loader alive:
    /// `AVAssetResourceLoader` holds its delegate weakly.
    static func makeAsset(url: URL, options: [String: Any], session: URLSession = .shared) -> AVURLAsset {
        let loader = RangeRequestLoader(sourceURL: url, session: session)
        let asset = AVURLAsset(url: loader.assetURL, options: options)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(asset, &associatedLoaderKey, loader, .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme?.hasPrefix(Self.schemePrefix) == true else { return false }
        let box = RequestBox(request: loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        // The task holds the loader weakly: AVFoundation doesn't cancel the open loading requests
        // of an asset it releases, so a strong reference would keep fetching to the end of the
        // file. Releasing the asset releases the loader, whose `deinit` cancels the tasks.
        tasks.withLock { tasks in
            tasks[key] = Task { [weak self] in
                await Self.serve(box) { [weak self] in self }
                _ = self?.tasks.withLock { $0.removeValue(forKey: key) }
            }
        }
        return true
    }

    deinit {
        tasks.withLock { tasks in
            for task in tasks.values { task.cancel() }
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.withLock { $0.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    // MARK: Serving

    /// Answers one loading request chunk by chunk. `loader` returns `nil` once the asset (and so
    /// the loader) is gone, which stops the loop between two fetches.
    private static func serve(_ box: RequestBox, loader: @Sendable () -> RangeRequestLoader?) async {
        guard let first = loader() else { return }
        let sourceHost = first.sourceURL.host() ?? "?"
        do {
            let (offset, length, wantsContentInfo) = await first.onQueue { () -> (Int64, Int64?, Bool) in
                guard let data = box.request.dataRequest else { return (0, 2, true) }
                let length: Int64? = data.requestsAllDataToEndOfResource ? nil : Int64(data.requestedLength)
                return (data.requestedOffset, length, box.request.contentInformationRequest != nil)
            }
            // A content-information request alone fetches two bytes, for the size and type.
            var next = offset
            var chunk = Int64(Self.initialChunk)
            // Every request is capped, bounded ones too: AVFoundation also asks for large explicit
            // ranges that it never cancels (measured: a released palette asset kept one streaming).
            var end: Int64? = offset + min(length ?? Self.maximumBytesPerRequest, Self.maximumBytesPerRequest)
            repeat {
                try Task.checkCancellation()
                guard let loader = loader() else { return }
                let upper = min(next + chunk, end ?? Int64.max) - 1
                let (data, contentInfo) = try await loader.fetch(next...upper)
                try Task.checkCancellation()
                let total = contentInfo.length
                end = min(end ?? total, total)
                let finished = next + Int64(data.count) >= (end ?? total) || data.isEmpty
                let stillWaiting = await loader.onQueue { () -> Bool in
                    guard !box.request.isCancelled else { return false }
                    if wantsContentInfo, let request = box.request.contentInformationRequest, request.contentLength == 0 {
                        request.contentType = contentInfo.uti
                        request.contentLength = total
                        request.isByteRangeAccessSupported = true
                    }
                    box.request.dataRequest?.respond(with: data)
                    if finished || box.request.dataRequest == nil { box.request.finishLoading() }
                    return !(finished || box.request.dataRequest == nil)
                }
                guard stillWaiting else { return }
                next += Int64(data.count)
                chunk = Int64(Self.followingChunk)
            } while true
        } catch is CancellationError {
            return
        } catch {
            logger.error("Range fetch failed for \(sourceHost, privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard let loader = loader() else { return }
            await loader.onQueue { if !box.request.isCancelled { box.request.finishLoading(with: error) } }
        }
    }

    /// Fetches `range` from the source and returns the body with the source's size and type.
    ///
    /// The first fetch (before the size is known) streams the response and checks the status
    /// before reading any of the body: a server that ignores `Range` answers 200 with the whole
    /// file, which must not be downloaded. Once a 206 has proved range support, later fetches
    /// are plain buffered requests, still refused unless they answer 206.
    func fetch(_ range: ClosedRange<Int64>) async throws -> (Data, ContentInfo) {
        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let limit = Int(range.upperBound - range.lowerBound + 1)
        let data: Data
        let response: URLResponse
        if info.withLock({ $0 }) == nil {
            let (bytes, streamed) = try await session.bytes(for: request)
            guard Self.isPartialContent(streamed) else {
                bytes.task.cancel()
                throw Self.noRangeSupport(streamed)
            }
            var body = Data()
            body.reserveCapacity(limit)
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
            }
            bytes.task.cancel()
            (data, response) = (body, streamed)
        } else {
            (data, response) = try await session.data(for: request)
            guard Self.isPartialContent(response) else { throw Self.noRangeSupport(response) }
        }
        guard let http = response as? HTTPURLResponse else { throw Self.noRangeSupport(response) }
        if let cached = info.withLock({ $0 }) { return (data, cached) }
        guard let total = RemoteVideoSupport.totalLength(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            expectedContentLength: http.expectedContentLength
        ) else {
            throw MosaicError.processingFailed("The source server did not report the file size")
        }
        let contentInfo = ContentInfo(length: total, uti: Self.uti(for: sourceURL, mimeType: http.mimeType))
        info.withLock { $0 = contentInfo }
        return (data, contentInfo)
    }

    private static func isPartialContent(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 206
    }

    private static func noRangeSupport(_ response: URLResponse) -> MosaicError {
        let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "not HTTP"
        return MosaicError.processingFailed(
            "The source server does not support byte-range requests (\(status)); turn off reduceSourceReads")
    }

    /// The type AVFoundation parses the source as: from the path extension, then the server's
    /// MIME type, else MPEG-4, the same default as ``RemoteVideoSupport/overrideMIMEType(for:)``.
    static func uti(for url: URL, mimeType: String?) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        if let mimeType, let type = UTType(mimeType: mimeType), type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        return UTType.mpeg4Movie.identifier
    }

    /// Runs `body` on ``queue``, where every call on a loading request is made.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

nonisolated(unsafe) private var associatedLoaderKey: UInt8 = 0
