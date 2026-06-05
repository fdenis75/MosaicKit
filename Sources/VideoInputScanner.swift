import Foundation

private let videoFileExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm",
    "3gp", "ts", "m2ts", "mts", "mxf", "f4v", "asf"
]

/// Scan a directory for video files and return a ``VideoInput`` for each one found.
///
/// Metadata (duration, resolution, frame rate, codec) is extracted automatically
/// from each file. Files whose metadata cannot be read are included with zeroed
/// fields rather than being silently dropped.
///
/// - Parameters:
///   - folder: The directory to scan.
///   - recursive: When `true`, all subdirectories are also scanned. Hidden files
///     and directories (names beginning with `.`) are always skipped.
/// - Returns: An array of ``VideoInput`` values sorted by filename, one per video
///   file discovered.
public func scanVideos(in folder: URL, recursive: Bool = false) async -> [VideoInput] {
    // Collect URLs synchronously to avoid Swift 6's restriction on calling
    // FileManager.DirectoryEnumerator.makeIterator() from async contexts.
    let videoURLs = collectVideoURLs(in: folder, recursive: recursive)

    var results: [VideoInput] = []
    results.reserveCapacity(videoURLs.count)
    for url in videoURLs {
        await results.append(VideoInput(url: url))
    }
    return results
}

// MARK: - Synchronous URL collection

private func collectVideoURLs(in folder: URL, recursive: Bool) -> [URL] {
    let fm = FileManager.default
    var urls: [URL] = []

    if recursive {
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        while let item = enumerator.nextObject() as? URL {
            guard
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                videoFileExtensions.contains(item.pathExtension.lowercased())
            else { continue }
            urls.append(item)
        }
    } else {
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        urls = contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            videoFileExtensions.contains($0.pathExtension.lowercased())
        }
    }

    urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    return urls
}
