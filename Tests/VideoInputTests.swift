import XCTest
@testable import MosaicKit
import AVFoundation

@available(macOS 26, iOS 26, *)
final class VideoInputTests: XCTestCase {

    // MARK: - Remote URL Tests

    /// Test initializing VideoInput from a remote URL
    /// This test verifies that VideoInput can properly extract metadata from a remote video file
    func testInitFromRemoteURL() async throws {
        // Given: A remote video URL
        let urlString = "https://n3.coomer.st/data/22/22/2222f147ab8bc374813f03435d2325a05407a96accc62bf78c3bd83bf1af086e.mp4"
        guard let url = URL(string: urlString) else {
            XCTFail("Failed to create URL from string")
            return
        }

        // When: Creating VideoInput from the URL
        let video = try await VideoInput(from: url)

        // Then: VideoInput should be properly initialized with metadata
        XCTAssertEqual(video.url, url, "URL should match the input URL")
        XCTAssertFalse(video.title.isEmpty, "Title should not be empty")

        // Verify basic video properties are populated
        XCTAssertNotNil(video.duration, "Duration should be extracted")
        XCTAssertNotNil(video.width, "Width should be extracted")
        XCTAssertNotNil(video.height, "Height should be extracted")
        XCTAssertNotNil(video.frameRate, "Frame rate should be extracted")

        // Verify duration is positive
        if let duration = video.duration {
            XCTAssertGreaterThan(duration, 0, "Duration should be positive")
        }

        // Verify dimensions are positive
        if let width = video.width {
            XCTAssertGreaterThan(width, 0, "Width should be positive")
        }
        if let height = video.height {
            XCTAssertGreaterThan(height, 0, "Height should be positive")
        }

        // Verify frame rate is positive
        if let frameRate = video.frameRate {
            XCTAssertGreaterThan(frameRate, 0, "Frame rate should be positive")
        }

        // Verify computed properties
        if video.width != nil && video.height != nil {
            let resolution = video.resolution
            XCTAssertNotNil(resolution, "Resolution should be computed")

            let aspectRatio = video.aspectRatio
            XCTAssertNotNil(aspectRatio, "Aspect ratio should be computed")
            if let ar = aspectRatio {
                XCTAssertGreaterThan(ar, 0, "Aspect ratio should be positive")
            }
        }

        // Log extracted metadata for verification
        print("\n=== Extracted Video Metadata ===")
        print("Title: \(video.title)")
        print("Duration: \(video.duration.map { "\($0)s" } ?? "nil")")
        print("Resolution: \(video.width.map { "\(Int($0))" } ?? "?")x\(video.height.map { "\(Int($0))" } ?? "?")")
        print("Frame Rate: \(video.frameRate.map { "\($0) fps" } ?? "nil")")
        print("File Size: \(video.fileSize.map { "\($0) bytes" } ?? "nil")")
        print("Codec: \(video.metadata.codec ?? "nil")")
        print("Bitrate: \(video.metadata.bitrate.map { "\($0) bps" } ?? "nil")")
        print("Aspect Ratio: \(video.aspectRatio.map { "\($0)" } ?? "nil")")
        print("================================\n")
    }

    /// Test that remote URL initialization handles network errors gracefully
    func testInitFromInvalidRemoteURL() async throws {
        // Given: An invalid remote URL
        let urlString = "https://invalid-domain-that-does-not-exist-12345.com/video.mp4"
        guard let url = URL(string: urlString) else {
            XCTFail("Failed to create URL from string")
            return
        }

        // When/Then: Creating VideoInput should throw an error
        do {
            _ = try await VideoInput(from: url)
            XCTFail("Expected initialization to fail for invalid URL")
        } catch {
            // Expected to fail
            print("Expected error for invalid URL: \(error.localizedDescription)")
        }
    }

    /// Test manual initialization with explicit metadata
    func testInitWithExplicitMetadata() {
        // Given: Explicit metadata
        let url = URL(string: "https://example.com/video.mp4")!
        let metadata = VideoMetadata(
            codec: "H.264",
            bitrate: 5_000_000,
            custom: ["test": "value"]
        )

        // When: Creating VideoInput with explicit values
        let video = VideoInput(
            url: url,
            title: "Test Video",
            duration: 120.0,
            width: 1920,
            height: 1080,
            frameRate: 30.0,
            fileSize: 50_000_000,
            metadata: metadata
        )

        // Then: All values should match
        XCTAssertEqual(video.url, url)
        XCTAssertEqual(video.title, "Test Video")
        XCTAssertEqual(video.duration, 120.0)
        XCTAssertEqual(video.width, 1920)
        XCTAssertEqual(video.height, 1080)
        XCTAssertEqual(video.frameRate, 30.0)
        XCTAssertEqual(video.fileSize, 50_000_000)
        XCTAssertEqual(video.metadata.codec, "H.264")
        XCTAssertEqual(video.metadata.bitrate, 5_000_000)
        XCTAssertEqual(video.metadata.custom["test"], "value")

        // Verify computed properties
        XCTAssertEqual(video.resolution?.width, 1920)
        XCTAssertEqual(video.resolution?.height, 1080)
        XCTAssertEqual(video.aspectRatio, 1920.0 / 1080.0)
    }

    /// Test that title defaults to filename when not provided
    func testInitDefaultTitle() {
        // Given: URL without explicit title
        let url = URL(string: "https://example.com/my-awesome-video.mp4")!

        // When: Creating VideoInput without title
        let video = VideoInput(url: url)

        // Then: Title should be the filename without extension
        XCTAssertEqual(video.title, "my-awesome-video")
    }

    /// Test VideoInput conformance to Codable
    func testCodableConformance() throws {
        // Given: A VideoInput instance
        let url = URL(string: "https://example.com/video.mp4")!
        let metadata = VideoMetadata(
            codec: "H.264",
            bitrate: 5_000_000,
            custom: ["key": "value"]
        )
        let original = VideoInput(
            url: url,
            title: "Test Video",
            duration: 120.0,
            width: 1920,
            height: 1080,
            frameRate: 30.0,
            fileSize: 50_000_000,
            metadata: metadata
        )

        // When: Encoding and decoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VideoInput.self, from: data)

        // Then: Decoded instance should match original
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        XCTAssertEqual(decoded.frameRate, original.frameRate)
        XCTAssertEqual(decoded.fileSize, original.fileSize)
        XCTAssertEqual(decoded.metadata.codec, original.metadata.codec)
        XCTAssertEqual(decoded.metadata.bitrate, original.metadata.bitrate)
        XCTAssertEqual(decoded.metadata.custom, original.metadata.custom)
    }

    /// Test VideoInput conformance to Hashable
    func testHashableConformance() {
        // Given: Two VideoInput instances
        let url1 = URL(string: "https://example.com/video1.mp4")!
        let url2 = URL(string: "https://example.com/video2.mp4")!

        let video1 = VideoInput(url: url1, title: "Video 1")
        let video2 = VideoInput(url: url2, title: "Video 2")
        let video1Copy = VideoInput(
            id: video1.id,
            url: video1.url,
            title: video1.title
        )

        // When: Adding to a Set
        var videoSet: Set<VideoInput> = []
        videoSet.insert(video1)
        videoSet.insert(video2)
        videoSet.insert(video1Copy)

        // Then: Set should contain unique videos
        XCTAssertEqual(videoSet.count, 2, "Set should contain 2 unique videos")
        XCTAssertTrue(videoSet.contains(video1))
        XCTAssertTrue(videoSet.contains(video2))
    }

    // MARK: - Performance Tests

    /// Test performance of remote URL metadata extraction
    func testRemoteURLPerformance() async throws {
        let urlString = "https://n1.coomer.st/data/59/47/594785876219dbb59646c0098a017bdf4612a6312d01576c9609d3293ac6b30f.mp4"
        guard let url = URL(string: urlString) else {
            XCTFail("Failed to create URL")
            return
        }

        measure {
            let expectation = XCTestExpectation(description: "Load video metadata")

            Task {
                do {
                    _ = try await VideoInput(from: url)
                    expectation.fulfill()
                } catch {
                    XCTFail("Failed to load video: \(error)")
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 30.0)
        }
    }

    // MARK: - Edge Cases

    /// Test with zero/nil values
    func testEdgeCaseValues() {
        let url = URL(string: "https://example.com/video.mp4")!

        // Test with nil optional values
        let video = VideoInput(
            url: url,
            title: "Test",
            duration: nil,
            width: nil,
            height: nil,
            frameRate: nil,
            fileSize: nil
        )

        XCTAssertNil(video.duration)
        XCTAssertNil(video.width)
        XCTAssertNil(video.height)
        XCTAssertNil(video.frameRate)
        XCTAssertNil(video.fileSize)
        XCTAssertNil(video.resolution)
        XCTAssertNil(video.aspectRatio)
    }

    /// Test aspect ratio calculation edge cases
    func testAspectRatioEdgeCases() {
        let url = URL(string: "https://example.com/video.mp4")!

        // Test with zero height
        let videoZeroHeight = VideoInput(
            url: url,
            width: 1920,
            height: 0
        )
        XCTAssertNil(videoZeroHeight.aspectRatio, "Aspect ratio should be nil when height is 0")

        // Test with nil dimensions
        let videoNilDimensions = VideoInput(url: url)
        XCTAssertNil(videoNilDimensions.aspectRatio, "Aspect ratio should be nil when dimensions are nil")

        // Test various aspect ratios
        let widescreen = VideoInput(url: url, width: 1920, height: 1080)
        XCTAssertNotNil(widescreen.aspectRatio)
        if let ar = widescreen.aspectRatio {
            XCTAssertEqual(ar, 1920.0 / 1080.0, accuracy: 0.001)
        }

        let portrait = VideoInput(url: url, width: 1080, height: 1920)
        XCTAssertNotNil(portrait.aspectRatio)
        if let ar = portrait.aspectRatio {
            XCTAssertEqual(ar, 1080.0 / 1920.0, accuracy: 0.001)
        }

        let square = VideoInput(url: url, width: 1000, height: 1000)
        XCTAssertNotNil(square.aspectRatio)
        if let ar = square.aspectRatio {
            XCTAssertEqual(ar, 1.0, accuracy: 0.001)
        }
    }
}

// MARK: - Test Helpers

@available(macOS 26, iOS 26, *)
extension VideoInputTests {

    /// Helper to print detailed video information
    private func printVideoInfo(_ video: VideoInput) {
        print("\n=== Video Information ===")
        print("ID: \(video.id)")
        print("URL: \(video.url)")
        print("Title: \(video.title)")
        print("Duration: \(video.duration ?? 0)s")
        print("Resolution: \(video.resolution?.width ?? 0)x\(video.resolution?.height ?? 0)")
        print("Frame Rate: \(video.frameRate ?? 0) fps")
        print("File Size: \(video.fileSize ?? 0) bytes")
        print("Codec: \(video.metadata.codec ?? "Unknown")")
        print("Bitrate: \(video.metadata.bitrate ?? 0) bps")
        print("Aspect Ratio: \(video.aspectRatio ?? 0)")
        print("========================\n")
    }
}
