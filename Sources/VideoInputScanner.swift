import Foundation

private let videoFileExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm",
    "3gp", "ts", "m2ts", "mts", "mxf", "f4v", "asf"
]

/// Legacy tolerant discovery. Use `discoverVideos` to observe failures and cancellation.
public func scanVideos(in folder: URL, recursive: Bool = false) async -> [VideoInput] {
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    guard let urls = try? collectVideoURLs(in: folder, recursive: recursive) else { return [] }
    var results: [VideoInput] = []
    for url in urls {
        guard !Task.isCancelled else { break }
        results.append(await VideoInput(url: url))
    }
    return results
}

/// Discovers sources without metadata loading. Enumeration errors are reported and cancellation is observed.
public func discoverVideoSources(in folder: URL, recursive: Bool = false) async throws -> [VideoSource] {
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    return try collectVideoURLs(in: folder, recursive: recursive).map { VideoSource(url: $0) }
}

/// Inspects discovered videos with at most `metadataConcurrency` simultaneous loads.
/// Results retain deterministic filename order. The first error cancels remaining inspections;
/// use ``discoverVideosReportingFailures(in:recursive:metadataConcurrency:)`` to keep going past
/// files that can't be inspected.
public func discoverVideos(
    in folder: URL, recursive: Bool = false, metadataConcurrency: Int = 2
) async throws -> [VideoInput] {
    try await discoverAndInspect(
        in: folder, recursive: recursive, metadataConcurrency: metadataConcurrency, stopOnFirstFailure: true
    ).outcomes.compactMap { try? $0.get() }
}

/// Like ``discoverVideos(in:recursive:metadataConcurrency:)``, but one undecodable file does not
/// abort the scan: files that fail inspection are collected in ``VideoDiscoveryReport/failures``
/// (with their error) and the rest are returned in ``VideoDiscoveryReport/videos``.
///
/// Still throws for a bad `metadataConcurrency`, for a folder that can't be enumerated, and with
/// `CancellationError` when the task is cancelled.
public func discoverVideosReportingFailures(
    in folder: URL, recursive: Bool = false, metadataConcurrency: Int = 2
) async throws -> VideoDiscoveryReport {
    let (urls, outcomes) = try await discoverAndInspect(
        in: folder, recursive: recursive, metadataConcurrency: metadataConcurrency, stopOnFirstFailure: false
    )
    var videos: [VideoInput] = []
    var failures: [VideoDiscoveryFailure] = []
    for (url, outcome) in zip(urls, outcomes) {
        switch outcome {
        case .success(let video): videos.append(video)
        case .failure(let error): failures.append(VideoDiscoveryFailure(url: url, error: error))
        }
    }
    return VideoDiscoveryReport(videos: videos, failures: failures)
}

/// Enumerates `folder` and inspects what it finds, holding the folder's security-scoped access
/// for the whole time (the files are only readable while it is open).
private func discoverAndInspect(
    in folder: URL, recursive: Bool, metadataConcurrency: Int, stopOnFirstFailure: Bool
) async throws -> (urls: [URL], outcomes: [Result<VideoInput, any Error>]) {
    guard (1...64).contains(metadataConcurrency) else {
        throw MosaicError.invalidConfiguration("Metadata concurrency must be between one and 64")
    }
    try Task.checkCancellation()
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    let urls = try collectVideoURLs(in: folder, recursive: recursive)
    let outcomes = try await inspect(urls, metadataConcurrency: metadataConcurrency, stopOnFirstFailure: stopOnFirstFailure)
    return (urls, outcomes)
}

/// Inspects `urls` with a sliding window of `metadataConcurrency` tasks. The outcomes keep the
/// order of `urls`. Cancellation always throws; with `stopOnFirstFailure` so does the first failed
/// inspection, which cancels the remaining ones.
private func inspect(
    _ urls: [URL], metadataConcurrency: Int, stopOnFirstFailure: Bool
) async throws -> [Result<VideoInput, any Error>] {
    try await withThrowingTaskGroup(of: (Int, Result<VideoInput, any Error>).self) { group in
        var nextIndex = 0
        var outcomes = [Result<VideoInput, any Error>?](repeating: nil, count: urls.count)
        func add(_ index: Int) {
            group.addTask {
                try Task.checkCancellation()
                do {
                    return (index, .success(try await VideoSource(url: urls[index]).inspect()))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return (index, .failure(error))
                }
            }
        }
        while nextIndex < min(metadataConcurrency, urls.count) {
            add(nextIndex)
            nextIndex += 1
        }
        while let (index, outcome) = try await group.next() {
            try Task.checkCancellation()
            if stopOnFirstFailure, case .failure(let error) = outcome { throw error }
            outcomes[index] = outcome
            if nextIndex < urls.count {
                add(nextIndex)
                nextIndex += 1
            }
        }
        try Task.checkCancellation()
        return outcomes.compactMap { $0 }
    }
}

private func collectVideoURLs(in folder: URL, recursive: Bool) throws -> [URL] {
    try Task.checkCancellation()
    let fm = FileManager.default
    var urls: [URL] = []
    guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw MosaicError.invalidVideo("Discovery source is not a directory")
    }
    if recursive {
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw MosaicError.invalidVideo("Unable to enumerate directory") }
        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
               videoFileExtensions.contains(item.pathExtension.lowercased()) {
                urls.append(item)
            }
        }
        if let enumerationError { throw enumerationError }
    } else {
        let contents = try fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        for item in contents {
            try Task.checkCancellation()
            if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
               videoFileExtensions.contains(item.pathExtension.lowercased()) {
                urls.append(item)
            }
        }
    }
    try Task.checkCancellation()
    urls.sort {
        let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
        return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
    }
    return urls
}
