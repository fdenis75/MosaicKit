import Foundation
import Testing
@testable import MosaicKit

/// I-30: remote sources (`https` download links without a file extension).
/// These tests never touch the network.
@Suite("Remote video sources")
struct RemoteVideoSourceTests {
    private let downloadLink = URL(string: "https://dl.example.com/download/?fid=abc&sign=123")!
    private let otherDownloadLink = URL(string: "https://dl.example.com/download/?fid=def&sign=456")!

    private func input(_ url: URL, title: String? = nil) -> VideoInput {
        VideoInput(canonicalID: UUID(), url: url, title: title, duration: 60, width: 1920, height: 1080)
    }

    @Test("Only remote URLs without a video extension get a MIME override")
    func mimeOverride() {
        #expect(RemoteVideoSupport.overrideMIMEType(for: downloadLink) == "video/mp4")
        #expect(RemoteVideoSupport.overrideMIMEType(for: URL(string: "https://host/get.php?id=1")!) == "video/mp4")
        #expect(RemoteVideoSupport.overrideMIMEType(for: URL(string: "https://host/clip.MP4?token=1")!) == nil)
        #expect(RemoteVideoSupport.overrideMIMEType(for: URL(string: "https://host/clip.mov")!) == nil)
        #expect(RemoteVideoSupport.overrideMIMEType(for: URL(fileURLWithPath: "/tmp/no-extension")) == nil)
    }

    @Test("Local and extension-bearing remote names are unchanged")
    func unchangedNames() {
        #expect(input(URL(fileURLWithPath: "/Volumes/Media/My Movie.mp4")).outputBaseName == "My Movie")
        #expect(input(URL(fileURLWithPath: "/Volumes/Media/My Movie.mp4"), title: "Other").outputBaseName == "My Movie")
        #expect(input(URL(string: "https://host/videos/clip.mp4?token=1")!).outputBaseName == "clip")
    }

    @Test("Extensionless download links get distinct, stable names")
    func downloadLinkNames() {
        let first = input(downloadLink).outputBaseName
        let second = input(otherDownloadLink).outputBaseName
        #expect(first.hasPrefix("download-"))
        #expect(first.count == "download-".count + 8)
        #expect(first != second)
        #expect(first == input(downloadLink).outputBaseName)
    }

    @Test("A supplied title names the outputs of a download link")
    func titleNamesDownloadLink() throws {
        #expect(input(downloadLink, title: "Holiday 2026").outputBaseName == "Holiday 2026")

        let config = MosaicConfiguration()
        let name = config.generateFilename(originalFilename: input(downloadLink, title: "Holiday").outputBaseName,
                                           videoInput: input(downloadLink, title: "Holiday"))
        #expect(name.hasPrefix("Holiday_"))
    }

    @Test("Content-Range and Content-Length give the remote size")
    func totalLength() {
        #expect(RemoteVideoSupport.totalLength(statusCode: 206, contentRange: "bytes 0-0/32220698", expectedContentLength: 1) == 32_220_698)
        #expect(RemoteVideoSupport.totalLength(statusCode: 206, contentRange: "bytes 0-0/*", expectedContentLength: 1) == nil)
        #expect(RemoteVideoSupport.totalLength(statusCode: 200, contentRange: nil, expectedContentLength: 5000) == 5000)
        #expect(RemoteVideoSupport.totalLength(statusCode: 200, contentRange: nil, expectedContentLength: -1) == nil)
        #expect(RemoteVideoSupport.totalLength(statusCode: 403, contentRange: nil, expectedContentLength: 100) == nil)
    }

    @Test("A remote mosaic needs an output directory")
    func mosaicOutputLocation() throws {
        var config = MosaicConfiguration()
        #expect(throws: MosaicError.self) { try config.validateOutputLocation(for: input(downloadLink)) }
        try config.validateOutputLocation(for: input(URL(fileURLWithPath: "/tmp/clip.mp4")))
        config.outputdirectory = FileManager.default.temporaryDirectory
        try config.validateOutputLocation(for: input(downloadLink))
    }

    @Test("A remote preview needs an output directory")
    func previewOutputLocation() throws {
        var config = PreviewConfiguration()
        config.outputDirectory = nil
        #expect(throws: PreviewError.self) { try config.validateOutputLocation(for: input(downloadLink)) }
        config.outputDirectory = FileManager.default.temporaryDirectory
        try config.validateOutputLocation(for: input(downloadLink))
    }

    @Test("Generating a remote mosaic without an output directory fails before any I/O")
    func generateRejectsRemoteWithoutOutputDirectory() async throws {
        let generator = try MetalMosaicGenerator()
        await #expect(throws: MosaicError.self) {
            _ = try await generator.generate(for: input(downloadLink), config: MosaicConfiguration())
        }
    }
}
