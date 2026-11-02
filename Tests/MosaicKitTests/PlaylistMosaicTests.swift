import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MosaicKit

/// Mosaics for the entries of a local `.m3u8` playlist, whose entries may be remote URLs (I-30).
///
/// The parser tests always run and never touch the network. The end-to-end test is opt-in:
///
/// ```
/// MOSAICKIT_PLAYLIST=/path/to/list.m3u8 swift test --filter PlaylistMosaicTests
/// ```
///
/// | Variable | Default | Meaning |
/// |---|---|---|
/// | `MOSAICKIT_PLAYLIST` | — (end-to-end test disabled) | A local `.m3u8` / `.m3u` playlist |
/// | `MOSAICKIT_PLAYLIST_OUTPUT` | `<playlist folder>/<playlist name>-mosaics` | Folder that receives the mosaics |
///
/// Every entry gets one mosaic: 1900 px wide, `XXL` density, 16:9, saved directly in the output
/// folder (no configuration-hash subfolder). An entry that cannot be opened is reported and
/// skipped, so the rest of the playlist is still generated.
@Suite("Playlist mosaics")
struct PlaylistMosaicTests {

    // MARK: - Parser (no network)

    @Test("Comments, EXTINF titles, absolute and relative URIs")
    func parsesExtendedPlaylist() throws {
        let base = URL(fileURLWithPath: "/Volumes/Media/lists", isDirectory: true)
        let text = """
        #EXTM3U

        #EXTINF:-1,Holiday 2026
        https://dl.example.com/download/?fid=abc&sign=123
        #EXTINF:87, Clip with extension
        https://host/videos/clip.mp4?token=1
        # a comment
        local/Movie.mp4
        /Volumes/Other/absolute.mov
        file:///Volumes/Media/file-url.mp4
        #EXTINF:10,
        https://host/untitled.m3u8
        """
        let entries = M3U8Playlist.parse(text, relativeTo: base)

        #expect(entries.count == 6)
        #expect(entries[0] == PlaylistEntry(url: URL(string: "https://dl.example.com/download/?fid=abc&sign=123")!, title: "Holiday 2026"))
        #expect(entries[1] == PlaylistEntry(url: URL(string: "https://host/videos/clip.mp4?token=1")!, title: "Clip with extension"))
        #expect(entries[2].url.isFileURL)
        #expect(entries[2].url.path == "/Volumes/Media/lists/local/Movie.mp4")
        #expect(entries[2].title == nil, "A title names only the entry that follows it")
        #expect(entries[3].url == URL(fileURLWithPath: "/Volumes/Other/absolute.mov"))
        #expect(entries[4].url == URL(string: "file:///Volumes/Media/file-url.mp4"))
        #expect(entries[5].url == URL(string: "https://host/untitled.m3u8"))
        #expect(entries[5].title == nil, "An empty EXTINF title is no title")
    }

    @Test("CRLF line endings and spaces in remote URLs")
    func parsesWindowsLineEndingsAndSpaces() throws {
        let text = "#EXTM3U\r\n#EXTINF:0,Spaced\r\nhttps://host/my clip.mp4\r\n"
        let entries = M3U8Playlist.parse(text, relativeTo: URL(fileURLWithPath: "/tmp", isDirectory: true))
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Spaced")
        #expect(entries.first?.url.absoluteString == "https://host/my%20clip.mp4")
    }

    @Test("A playlist file is read relative to its own folder")
    func parsesPlaylistFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicKitPlaylist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let playlist = folder.appendingPathComponent("list.m3u8")
        try "#EXTM3U\n#EXTINF:5,Local\nclips/a.mp4\nhttps://host/b.mp4\n".write(to: playlist, atomically: true, encoding: .utf8)

        let entries = try M3U8Playlist.parse(contentsOf: playlist)
        #expect(entries.count == 2)
        #expect(entries[0].url.standardizedFileURL.path == folder.appendingPathComponent("clips/a.mp4").standardizedFileURL.path)
        #expect(entries[0].title == "Local")
        #expect(entries[1].url.absoluteString == "https://host/b.mp4")
    }

    // MARK: - End to end (opt-in)

    @Test("One 1900 px XXL 16:9 mosaic per entry of MOSAICKIT_PLAYLIST")
       //   .enabled(if: ProcessInfo.processInfo.environment["MOSAICKIT_PLAYLIST"] != nil,
      //             "Set MOSAICKIT_PLAYLIST=/path/to/list.m3u8 to run"))
    func generatesMosaicsForPlaylist() async throws {
        let env = ProcessInfo.processInfo.environment
        let playlistURL = URL(fileURLWithPath: "/Users/francois/Dev26/pik/playlist.m3u8").standardizedFileURL
        try #require(FileManager.default.fileExists(atPath: playlistURL.path), "No playlist at \(playlistURL.path)")

        let entries = try M3U8Playlist.parse(contentsOf: playlistURL)
        try #require(!entries.isEmpty, "No media entries in \(playlistURL.lastPathComponent)")

        let outputDir = env["MOSAICKIT_PLAYLIST_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? playlistURL.deletingLastPathComponent()
                .appendingPathComponent(playlistURL.deletingPathExtension().lastPathComponent + "-mosaics", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Inspect every entry first (remote metadata needs the network). A dead link fails the
        // test but does not stop the others.
        var videos: [VideoInput] = []
        for entry in entries {
            try Task.checkCancellation()
            do {
                videos.append(try await VideoSource(url: entry.url, title: entry.title).inspect())
            } catch {
                Issue.record("Cannot open \(entry.title ?? entry.url.absoluteString): \(error.localizedDescription)")
            }
        }
        try #require(!videos.isEmpty, "No entry of \(playlistURL.lastPathComponent) could be opened")

        var config = MosaicConfiguration(
            width: 1900,
            density: .xxl,
            layout: LayoutConfiguration(aspectRatio: .widescreen, layoutType: .custom),
            outputdirectory: outputDir
        )
        config.createOutputSubdirectory = false
        config.overwrite = true
        config.gifMode = .disabled

        let coordinator = try createDefaultMosaicCoordinator()
        let results = try await coordinator.generateMosaicsforbatch(videos: videos, config: config) { _ in }
        #expect(results.count == videos.count)

        var outputs: [URL] = []
        for result in results {
            guard let outputURL = result.outputURL, result.error == nil else {
                Issue.record("\(result.video.title): \(result.error?.localizedDescription ?? "no output")")
                continue
            }
            outputs.append(outputURL)
            #expect(outputURL.deletingLastPathComponent().standardizedFileURL.path == outputDir.standardizedFileURL.path,
                    "\(outputURL.lastPathComponent) was not saved in \(outputDir.path)")
            #expect(try Self.pixelWidth(of: outputURL) == 1900, "\(outputURL.lastPathComponent) is not 1900 px wide")
        }
        #expect(Set(outputs.map(\.lastPathComponent)).count == outputs.count, "Two entries shared an output name")

        print("Playlist mosaics (\(outputs.count)/\(entries.count)) in \(outputDir.path):")
        for url in outputs { print("  \(url.lastPathComponent)") }
    }

    private static func pixelWidth(of url: URL) throws -> Int {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "Cannot read \(url.lastPathComponent)")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    }
}

// MARK: - M3U8 parsing

/// One media entry of an extended M3U playlist.
struct PlaylistEntry: Equatable, Sendable {
    let url: URL
    /// The `#EXTINF` title of the line before the URI, if any.
    let title: String?
}

/// A minimal reader for `.m3u` / `.m3u8` playlists (extended M3U, UTF-8), test-side only.
///
/// Lines starting with `#` are tags or comments; `#EXTINF:<duration>,<title>` names the entry
/// that follows it. Every other non-empty line is a URI: an absolute URL (`https://…`,
/// `file://…`), an absolute or `~` path, or a path relative to the playlist's folder.
enum M3U8Playlist {
    static func parse(contentsOf fileURL: URL) throws -> [PlaylistEntry] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return parse(text, relativeTo: fileURL.deletingLastPathComponent())
    }

    static func parse(_ text: String, relativeTo base: URL) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pendingTitle: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:"), let comma = line.firstIndex(of: ",") {
                    let title = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    pendingTitle = title.isEmpty ? nil : title
                }
                continue
            }
            if let url = resolve(line, relativeTo: base) {
                entries.append(PlaylistEntry(url: url, title: pendingTitle))
            }
            pendingTitle = nil
        }
        return entries
    }

    /// `uri` as a URL: a scheme makes it absolute (percent-encoding spaces and other unsafe
    /// characters if needed); anything else is a file path, resolved against `base`.
    static func resolve(_ uri: String, relativeTo base: URL) -> URL? {
        if uri.contains("://") {
            if let url = URL(string: uri), url.scheme != nil { return url }
            let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))
            return uri.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
        }
        if uri.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: uri).expandingTildeInPath)
        }
        if uri.hasPrefix("/") {
            return URL(fileURLWithPath: uri)
        }
        return URL(fileURLWithPath: uri, relativeTo: base).absoluteURL
    }
}
