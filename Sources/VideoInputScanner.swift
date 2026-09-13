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
/// Results retain deterministic filename order. The first error cancels remaining inspections.
public func discoverVideos(
    in folder: URL, recursive: Bool = false, metadataConcurrency: Int = 2
) async throws -> [VideoInput] {
    guard (1...64).contains(metadataConcurrency) else {
        throw MosaicError.invalidConfiguration("Metadata concurrency must be between one and 64")
    }
    try Task.checkCancellation()
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    let urls = try collectVideoURLs(in: folder, recursive: recursive)
    return try await withThrowingTaskGroup(of: (Int, VideoInput).self) { group in
        var nextIndex = 0
        var results: [VideoInput?] = Array(repeating: nil, count: urls.count)
        func add(_ index: Int) {
            group.addTask {
                try Task.checkCancellation()
                return (index, try await VideoSource(url: urls[index]).inspect())
            }
        }
        while nextIndex < min(metadataConcurrency, urls.count) {
            add(nextIndex)
            nextIndex += 1
        }
        while let (index, video) = try await group.next() {
            try Task.checkCancellation()
            results[index] = video
            if nextIndex < urls.count {
                add(nextIndex)
                nextIndex += 1
            }
        }
        try Task.checkCancellation()
        return results.compactMap { $0 }
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
