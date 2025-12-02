import XCTest
@testable import MosaicKit
import AVFoundation

@available(macOS 26, iOS 26, *)
final class VideoInputPerformanceTests: XCTestCase {

    // Test video URLs
    private let testVideoURLs: [String] = [
        "https://n1.coomer.st/data/ca/28/ca28890b54a18b5f2927a2d58528f053bd33f8cd3c2ed898512aae482d849d3f.mp4",
        "https://n2.coomer.st/data/cd/e6/cde61a54fc6c59504ecb8a91045ef4898e513481150535694c28c447158b920e.mp4",
        "https://n2.coomer.st/data/cb/3d/cb3d2e66e98a668d1f67aa3c944411cd6807e403f26ace44794e44013dfc56cd.mp4",
        "https://n4.coomer.st/data/68/01/68018b924872487a86a8964103f5733ccc3a6cbe9f21666cc9f770812fa2f1e3.mp4",
        "https://n1.coomer.st/data/bd/dd/bddd468108264b08e021976fc25c3ced38db2873bca12593afab87a9d40c3394.mp4",
        "https://n4.coomer.st/data/f2/d0/f2d05971e9a24184e3e9cad792d12122e664a04992466dc1e0a6f8aecfb88bdc.mp4",
        "https://n2.coomer.st/data/ce/0f/ce0f7378da5dc062b0056a42446d5882f67443ab27367aac5449333e5497bc4e.mp4",
        "https://n1.coomer.st/data/dd/d4/ddd4dd0f9fbffb9430bcd6aa1e0d36b853490f5d7f3e770e59c722fd44358149.mp4",
        "https://n2.coomer.st/data/de/31/de31a44c37a48602b3033113d2050345e969888cb412a0f0e1ef814dfa72eb8a.mp4",
        "https://n3.coomer.st/data/39/64/3964a90fda12e934b8ea7a94a22ad8a97717dbbdef66637da63f07ec348ade4d.mp4",
        "https://n2.coomer.st/data/93/c4/93c427ad32bfc70a7afcc825deb654f00cfb6372828fafd4fa1c5059d149c870.mp4",
        "https://n3.coomer.st/data/d2/54/d2541ac9fa508890467e5bef8cd20ad27722e63d69ac1adfca5f35aeae43018b.mp4",
        "https://n1.coomer.st/data/98/a0/98a0bf57998670a53982c0124646d6fe7a423bb4e4e9fc7d2f95d24d8bfd4f92.mp4",
        "https://n2.coomer.st/data/4a/49/4a49d2ab615b92551f2e5b72bc5f0a8c99fab3be386b06b09712ebdd01808d7e.mp4",
        "https://n2.coomer.st/data/e3/59/e3593fb160d3b2c8ffbb5f204f9f3284ef9db65012399d70cb1d58fc50863fb5.mp4",
        "https://n4.coomer.st/data/b7/87/b7872bf65b7ad4d9602b232ddac781ef183e431fcdccb20ee4bccd4bd9e14dd6.mp4",
        "https://n4.coomer.st/data/99/e9/99e91d714f6f0f9656089ba320d3e38772c53ebff3559d390f5f5b660313cadf.mp4",
        "https://n2.coomer.st/data/0d/6c/0d6cde2048e84af94f594753ec33a0f4ebc4a0e9858cca34c554051b0ecb963d.mp4",
        "https://n2.coomer.st/data/92/b9/92b965297953e878052d3d07b961cb8848f90f9ed3964833ecf8d5a6044dcf94.mp4",
        "https://n4.coomer.st/data/3f/ee/3feedaea65b6413ba32017cd552916105b46a3eee7819ece0ab22a3e96a6c4da.mp4",
        "https://n3.coomer.st/data/1b/b4/1bb4961bc1329b3c302b0c25d4284eadb5a11300cbbb9ef268f9f108ea9f1559.mp4",
        "https://n1.coomer.st/data/2d/96/2d9605e29d1f3747e46b02559e0faa67c07810ab1c8abf6869fae084924dd867.mp4",
        "https://n3.coomer.st/data/90/ac/90ac52eab30b02cfea3cc875618f47ed590533000ef7d001def846e182970260.mp4",
        "https://n1.coomer.st/data/5a/21/5a215054f677df0d2c13cc2c847e6bc2ced302bc32f77edd7c384c826de84ead.mp4",
        "https://n4.coomer.st/data/a7/ce/a7ce954969cccf5e7f62b3407d4d7fe9cd1fbc8b52b8f4eae45921439c3d9509.mp4",
        "https://n3.coomer.st/data/2d/db/2ddbec34dbca7e96c8e54425ec7b00782bd595f730e4dfbc94b764e44b316bbb.mp4",
        "https://n4.coomer.st/data/79/8b/798b7f04d18aa46ffb46c0529eb77f598e696535e00404a14ca53c84c933f9cf.mp4",
        "https://n1.coomer.st/data/bd/d5/bdd5aa5c72626e5ef6c7ac9ce51794575f40f9af9444525cc261e9d86ec6f081.mp4",
        "https://n1.coomer.st/data/fe/3d/fe3dcf690942725a01cb28dbe6b361cb30363c1e31a8cdeb810eee0220a22664.mp4",
        "https://n4.coomer.st/data/13/40/13408f40a315104b07ebda0e02b12ec079088eb869369eb3e66c9be05257c3e6.mp4",
        "https://n4.coomer.st/data/3b/3b/3b3b0544872f9e1a9e31cbfb2f3e469674422d5c24380e923361c7d9a8907023.mp4",
        "https://n1.coomer.st/data/23/71/2371866a71bc7b9b76ff6a0abcbce40abdd122d0bf771216ddd24ee1692653d6.mp4",
        "https://n3.coomer.st/data/df/da/dfda4f148159e2c24fd2f1ff51f097d291cec4558291944ae47403138052381a.mp4",
        "https://n3.coomer.st/data/fb/21/fb211063be374605e6e3f45f8c4f7e728b59afbe781f15d0d39e38d41cd582b9.mp4",
        "https://n2.coomer.st/data/69/1a/691ab4622f08307d16ab0b498c6f7bb2f2822f5d7b142e4619a6f5bd1ea137dd.mp4",
        "https://n2.coomer.st/data/03/4d/034d6593343195d30a689c3298d3cc9e47a3b213f135d2129549bc9cb5be781d.mp4",
        "https://n1.coomer.st/data/0a/97/0a974495f3e49416a06b2971d470a72a075aea984c27d2cb74368b3757f34e67.mp4",
        "https://n3.coomer.st/data/a5/67/a567de41c80d8d27a3ee9ab04db2ffd526f0f5a08caa8413ac0b77a535ac5032.mp4",
        "https://n4.coomer.st/data/7c/6a/7c6a991d01cfa00aa0ee7de67394071cfebc79027d0627c62c258f7be1b198e0.mp4",
        "https://n1.coomer.st/data/a0/6c/a06c77d3a6f4e3a70effa39a9cec3845303e6ecd88e7bb23eec1219c12074b61.mp4",
        "https://n4.coomer.st/data/c8/0f/c80fff776075954bfbd923c5c47e0e6bc8520e4656fc50ed78a5ece3e95a6bfa.mp4",
        "https://n1.coomer.st/data/25/5a/255a9dfa80deaf8802dadf3df8a5a52a0e101f9e4b73b2d2d73013ef7c016ef9.mp4",
        "https://n4.coomer.st/data/ee/7f/ee7fb81e10e9cc6cb75e041dea2afc03c901ae1ecf3f279a6d5f7384b9eefe77.mp4",
        "https://n1.coomer.st/data/8c/30/8c30f602d23fa0dfa1476387e2a9552420944da8fc389d9f4e07c5c12549e06e.mp4",
        "https://n1.coomer.st/data/b1/a0/b1a04c94bc68282cee3549ccd55464ac037a36a5e080eff37e8355e7766bff8b.mp4",
        "https://n2.coomer.st/data/fd/a1/fda1d0bbce35ae211e10a7ebad2cf6bf118d902a3b982a4a31400ec05b79ac41.mp4",
        "https://n3.coomer.st/data/07/31/0731ca1969a60de8c9d5828e5ff8d948dd6662aceb65df00ef81332e73244f21.mp4",
        "https://n1.coomer.st/data/11/89/1189d3cc61e6830ae2e19a709da5953ceefba7a6fb191eb9213161119ff75307.mp4",
        "https://n1.coomer.st/data/df/2b/df2bb3dc349f7a941a1bcfaaef842cd0ed27af3ed0db03b98f0c2fe95cfd2120.mp4",
        "https://n4.coomer.st/data/8c/b9/8cb9998a0e76ab8251aeb32ab171d0b12812fd29b52c569361602c3723117538.mp4",
        "https://n4.coomer.st/data/14/54/1454decdba360d231f4b299b827fbffedec1c7c85181debe6d8e773d8c43d1a8.mp4",
        "https://n4.coomer.st/data/cb/ac/cbac33be0f7576e46cff1b61dcee6c628979e1fe6a4d0cd02a17d136c3a9e07e.mp4",
        "https://n2.coomer.st/data/64/41/6441d3ba63f30493e3b3e59e4bc165b0e9da96ba364287ab3a6f51fb318ad375.mp4",
        "https://n3.coomer.st/data/68/25/6825c10205e021ce947a49e8b4ae155938c3aca9e7efafe6120d203cd33b33a7.mp4",

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
