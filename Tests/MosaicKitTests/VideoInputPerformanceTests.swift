import XCTest
@testable import MosaicKit
import AVFoundation

@available(macOS 15, iOS 18, *)
final class VideoInputPerformanceTests: XCTestCase {

    // Test video URLs
    private let testVideoURLs: [String] = [
        "https://n2.coomer.st/data/ad/04/ad04236848a164e35cf1265a82a0a721c7b2e1604d1a840cf4f0e92f4d9bd4dc.mp4",
        "https://n4.coomer.st/data/72/a8/72a833202a65e9b605a989ce5750a567002496273ef3433076d92ecddeef0c35.mp4",
        "https://n1.coomer.st/data/4f/df/4fdf970e372aee5874a80dfa46e180418e8858d3cdf186028bfdff29105af8d8.mp4",
        "https://n3.coomer.st/data/4b/9d/4b9db06d2b672df1e94c4531bc7b71262336c2ee53566bfbde2ea4e657f01d70.mp4",
        "https://n1.coomer.st/data/96/56/9656312fe25bd96a5d7a6081486604d4fe0ddd983aee9e3f3ce29e180f6f05f7.mp4"
    ]

    // MARK: - Sequential Loading Tests

    /// Test sequential loading of multiple videos
    func testSequentialVideoLoading() async throws {
        print("\n" + "=" * 70)
        print("🔄 SEQUENTIAL VIDEO LOADING TEST")
        print("=" * 70)

        let startTime = Date()
        var loadedVideos: [VideoInput] = []
        var individualTimes: [TimeInterval] = []

        for (index, urlString) in testVideoURLs.enumerated() {
            guard let url = URL(string: urlString) else {
                XCTFail("Invalid URL: \(urlString)")
                continue
            }

            let videoStartTime = Date()
            print("\n[\(index + 1)/\(testVideoURLs.count)] Loading: \(url.lastPathComponent)")

            do {
                let video = try await VideoInput(from: url)
                let loadTime = Date().timeIntervalSince(videoStartTime)
                individualTimes.append(loadTime)
                loadedVideos.append(video)

                print("  ✅ Success in \(String(format: "%.3f", loadTime))s")
                printVideoSummary(video, loadTime: loadTime)
            } catch {
                print("  ❌ Failed: \(error.localizedDescription)")
                XCTFail("Failed to load video \(index + 1): \(error)")
            }
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Print summary
        print("\n" + "-" * 70)
        print("SEQUENTIAL LOADING SUMMARY")
        print("-" * 70)
        print("Total videos loaded: \(loadedVideos.count)/\(testVideoURLs.count)")
        print("Total time: \(String(format: "%.3f", totalTime))s")
        print("Average time per video: \(String(format: "%.3f", individualTimes.average))s")
        print("Min time: \(String(format: "%.3f", individualTimes.min() ?? 0))s")
        print("Max time: \(String(format: "%.3f", individualTimes.max() ?? 0))s")
        print("=" * 70 + "\n")

        // Assertions
        XCTAssertEqual(loadedVideos.count, testVideoURLs.count, "Should load all videos")
        XCTAssertGreaterThan(totalTime, 0, "Total time should be positive")
    }

    /// Test sequential loading with detailed metrics
    func testSequentialLoadingWithMetrics() async throws {
        print("\n" + "=" * 70)
        print("📊 SEQUENTIAL LOADING WITH DETAILED METRICS")
        print("=" * 70)

        var metrics: [(url: String, loadTime: TimeInterval, video: VideoInput)] = []
        let overallStart = Date()

        for (index, urlString) in testVideoURLs.enumerated() {
            guard let url = URL(string: urlString) else { continue }

            let start = Date()
            if let video = try? await VideoInput(from: url) {
                let loadTime = Date().timeIntervalSince(start)
                metrics.append((url: url.lastPathComponent, loadTime: loadTime, video: video))
                print("[\(index + 1)] \(url.lastPathComponent): \(String(format: "%.3f", loadTime))s")
            }
        }

        let totalTime = Date().timeIntervalSince(overallStart)

        // Analyze metrics
        print("\n" + "-" * 70)
        print("DETAILED METRICS")
        print("-" * 70)

        for (index, metric) in metrics.enumerated() {
            print("\nVideo \(index + 1): \(metric.url)")
            print("  Load Time: \(String(format: "%.3f", metric.loadTime))s")
            print("  Duration: \(metric.video.duration.map { String(format: "%.1f", $0) } ?? "?")s")
            print("  Resolution: \(Int(metric.video.width ?? 0))x\(Int(metric.video.height ?? 0))")
            print("  Frame Rate: \(String(format: "%.2f", metric.video.frameRate ?? 0)) fps")
            print("  Codec: \(metric.video.metadata.codec ?? "Unknown")")
        }

        print("\nTotal Sequential Time: \(String(format: "%.3f", totalTime))s")
        print("=" * 70 + "\n")

        XCTAssertEqual(metrics.count, testVideoURLs.count)
    }

    // MARK: - Concurrent Loading Tests

    /// Test concurrent loading of multiple videos
    func testConcurrentVideoLoading() async throws {
        print("\n" + "=" * 70)
        print("⚡ CONCURRENT VIDEO LOADING TEST")
        print("=" * 70)

        let startTime = Date()
        var loadedVideos: [VideoInput] = []
        var loadTimes: [String: TimeInterval] = [:]

        await withTaskGroup(of: (String, VideoInput?, TimeInterval).self) { group in
            for (index, urlString) in testVideoURLs.enumerated() {
                guard let url = URL(string: urlString) else { continue }

                group.addTask {
                    let taskStart = Date()
                    print("[\(index + 1)] Starting: \(url.lastPathComponent)")

                    do {
                        let video = try await VideoInput(from: url)
                        let loadTime = Date().timeIntervalSince(taskStart)
                        print("[\(index + 1)] ✅ Completed: \(url.lastPathComponent) in \(String(format: "%.3f", loadTime))s")
                        return (url.lastPathComponent, video, loadTime)
                    } catch {
                        print("[\(index + 1)] ❌ Failed: \(url.lastPathComponent) - \(error.localizedDescription)")
                        return (url.lastPathComponent, nil, 0)
                    }
                }
            }

            for await (filename, video, loadTime) in group {
                if let video = video {
                    loadedVideos.append(video)
                    loadTimes[filename] = loadTime
                }
            }
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let times = Array(loadTimes.values)

        // Print summary
        print("\n" + "-" * 70)
        print("CONCURRENT LOADING SUMMARY")
        print("-" * 70)
        print("Total videos loaded: \(loadedVideos.count)/\(testVideoURLs.count)")
        print("Total time (concurrent): \(String(format: "%.3f", totalTime))s")
        print("Average individual load time: \(String(format: "%.3f", times.average))s")
        print("Min load time: \(String(format: "%.3f", times.min() ?? 0))s")
        print("Max load time: \(String(format: "%.3f", times.max() ?? 0))s")
        print("Speedup vs sequential: ~\(String(format: "%.2f", times.reduce(0, +) / totalTime))x")
        print("=" * 70 + "\n")

        // Assertions
        XCTAssertEqual(loadedVideos.count, testVideoURLs.count, "Should load all videos")
        XCTAssertGreaterThan(totalTime, 0, "Total time should be positive")
    }

    /// Test concurrent loading with structured concurrency
    func testConcurrentLoadingStructured() async throws {
        print("\n" + "=" * 70)
        print("🔀 STRUCTURED CONCURRENT LOADING TEST")
        print("=" * 70)

        let startTime = Date()

        let results = try await withThrowingTaskGroup(of: (Int, VideoInput, TimeInterval).self) { group in
            for (index, urlString) in testVideoURLs.enumerated() {
                guard let url = URL(string: urlString) else { continue }

                group.addTask {
                    let taskStart = Date()
                    let video = try await VideoInput(from: url)
                    let loadTime = Date().timeIntervalSince(taskStart)
                    return (index, video, loadTime)
                }
            }

            var collected: [(Int, VideoInput, TimeInterval)] = []
            for try await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Print results in order
        print("\nLoaded Videos (in order):")
        for (index, video, loadTime) in results {
            print("[\(index + 1)] \(video.title)")
            print("     Load Time: \(String(format: "%.3f", loadTime))s")
            print("     Duration: \(video.duration.map { String(format: "%.1f", $0) } ?? "?")s")
            print("     Resolution: \(Int(video.width ?? 0))x\(Int(video.height ?? 0))")
        }

        let loadTimes = results.map { $0.2 }

        print("\n" + "-" * 70)
        print("Total concurrent time: \(String(format: "%.3f", totalTime))s")
        print("Sum of individual times: \(String(format: "%.3f", loadTimes.reduce(0, +)))s")
        print("Concurrency efficiency: \(String(format: "%.1f", (loadTimes.reduce(0, +) / totalTime * 100)))%")
        print("=" * 70 + "\n")

        XCTAssertEqual(results.count, testVideoURLs.count)
    }

    // MARK: - Comparison Tests

    /// Compare sequential vs concurrent loading performance
    func testSequentialVsConcurrentComparison() async throws {
        print("\n" + "=" * 70)
        print("⚖️  SEQUENTIAL VS CONCURRENT COMPARISON")
        print("=" * 70)

        // Sequential loading
        print("\n1️⃣ Testing Sequential Loading...")
        let sequentialStart = Date()
        var sequentialVideos: [VideoInput] = []

        for urlString in testVideoURLs {
            guard let url = URL(string: urlString) else { continue }
            if let video = try? await VideoInput(from: url) {
                sequentialVideos.append(video)
            }
        }

        let sequentialTime = Date().timeIntervalSince(sequentialStart)
        print("   Sequential time: \(String(format: "%.3f", sequentialTime))s")

        // Small delay between tests
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Concurrent loading
        print("\n2️⃣ Testing Concurrent Loading...")
        let concurrentStart = Date()
        var concurrentVideos: [VideoInput] = []

        await withTaskGroup(of: VideoInput?.self) { group in
            for urlString in testVideoURLs {
                guard let url = URL(string: urlString) else { continue }

                group.addTask {
                    try? await VideoInput(from: url)
                }
            }

            for await video in group {
                if let video = video {
                    concurrentVideos.append(video)
                }
            }
        }

        let concurrentTime = Date().timeIntervalSince(concurrentStart)
        print("   Concurrent time: \(String(format: "%.3f", concurrentTime))s")

        // Calculate metrics
        let speedup = sequentialTime / concurrentTime
        let timeSaved = sequentialTime - concurrentTime
        let efficiency = (speedup / Double(testVideoURLs.count)) * 100

        print("\n" + "=" * 70)
        print("COMPARISON RESULTS")
        print("=" * 70)
        print("Sequential time:     \(String(format: "%.3f", sequentialTime))s")
        print("Concurrent time:     \(String(format: "%.3f", concurrentTime))s")
        print("Time saved:          \(String(format: "%.3f", timeSaved))s (\(String(format: "%.1f", (timeSaved / sequentialTime) * 100))%)")
        print("Speedup factor:      \(String(format: "%.2f", speedup))x")
        print("Parallel efficiency: \(String(format: "%.1f", efficiency))%")
        print("Videos loaded:       \(concurrentVideos.count)/\(testVideoURLs.count)")
        print("=" * 70 + "\n")

        // Assertions
        XCTAssertEqual(sequentialVideos.count, testVideoURLs.count)
        XCTAssertEqual(concurrentVideos.count, testVideoURLs.count)
        XCTAssertLessThan(concurrentTime, sequentialTime, "Concurrent loading should be faster")
        XCTAssertGreaterThan(speedup, 1.0, "Should have speedup from concurrency")
    }

    // MARK: - XCTest Performance Measurement

    /// XCTest performance measurement for sequential loading
    func testSequentialLoadingPerformance() {
        let urls = testVideoURLs // Capture to avoid self reference
        measure {
            let expectation = XCTestExpectation(description: "Load videos sequentially")

            Task { @MainActor in
                var count = 0
                for urlString in urls {
                    guard let url = URL(string: urlString) else { continue }
                    if let _ = try? await VideoInput(from: url) {
                        count += 1
                    }
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 60.0)
        }
    }

    /// XCTest performance measurement for concurrent loading
    func testConcurrentLoadingPerformance() {
        let urls = testVideoURLs // Capture to avoid self reference
        measure {
            let expectation = XCTestExpectation(description: "Load videos concurrently")

            Task { @MainActor in
                await withTaskGroup(of: VideoInput?.self) { group in
                    for urlString in urls {
                        guard let url = URL(string: urlString) else { continue }
                        group.addTask {
                            try? await VideoInput(from: url)
                        }
                    }

                    var count = 0
                    for await video in group {
                        if video != nil {
                            count += 1
                        }
                    }
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 60.0)
        }
    }

    // MARK: - Helper Methods

    private func printVideoSummary(_ video: VideoInput, loadTime: TimeInterval) {
        print("  Duration: \(video.duration.map { String(format: "%.1f", $0) } ?? "?")s")
        print("  Resolution: \(Int(video.width ?? 0))x\(Int(video.height ?? 0))")
        print("  Frame Rate: \(String(format: "%.2f", video.frameRate ?? 0)) fps")
        print("  Codec: \(video.metadata.codec ?? "?")")
        print("  Bitrate: \(formatBitrate(video.metadata.bitrate))")
    }

    private func formatBitrate(_ bitrate: Int64?) -> String {
        guard let bitrate = bitrate else { return "Unknown" }
        let mbps = Double(bitrate) / 1_000_000.0
        return String(format: "%.2f Mbps", mbps)
    }
}

// MARK: - Array Extension for Statistics

extension Array where Element == TimeInterval {
    var average: TimeInterval {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

// MARK: - String Multiplication Extension

extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}
