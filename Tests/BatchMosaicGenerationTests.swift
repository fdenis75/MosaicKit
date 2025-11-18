import XCTest
@testable import MosaicKit
import AVFoundation
@preconcurrency import SwiftData

@available(macOS 15, iOS 18, *)
final class BatchMosaicGenerationTests: XCTestCase {

    // MARK: - Model Context Setup

    private nonisolated(unsafe) var modelContainer: ModelContainer!
    private nonisolated(unsafe) var modelContext: ModelContext!

    // MARK: - Properties

    /// Output directory for generated mosaics
    private let outputDirectory = URL(fileURLWithPath: "/Volumes/Ext-6TB-2/bree")

    /// Test video URLs (reused from VideoInputTests)
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


    // MARK: - Setup & Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create output directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        print("\n📂 Output directory: \(outputDirectory.path)")
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    /// Create a fresh ModelContext for each test run
    private nonisolated(unsafe) func createModelContext() throws -> ModelContext {
        let schema = Schema([])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    // MARK: - Batch Generation Tests

    /// Test batch mosaic generation with 1000px width, XXL density
    func testBatchGeneration1000pxXXL() async throws {
        try await runBatchGenerationTest(
            width: 1000,
            density: .xxl,
            testName: "1000px_XXL"
        )
    }

    /// Test batch mosaic generation with 1000px width, M density
    func testBatchGeneration1000pxM() async throws {
        try await runBatchGenerationTest(
            width: 1000,
            density: .m,
            testName: "1000px_M"
        )
    }

    /// Test batch mosaic generation with 1000px width, S density
    func testBatchGeneration1000pxS() async throws {
        try await runBatchGenerationTest(
            width: 1000,
            density: .s,
            testName: "1000px_S"
        )
    }

    /// Test batch mosaic generation with 1000px width, XS density
    func testBatchGeneration1000pxXS() async throws {
        try await runBatchGenerationTest(
            width: 1000,
            density: .xs,
            testName: "1000px_XS"
        )
    }

    /// Test batch mosaic generation with 2000px width, XXL density
    func testBatchGeneration2000pxXXL() async throws {
        try await runBatchGenerationTest(
            width: 2000,
            density: .xxl,
            testName: "2000px_XXL"
        )
    }

    /// Test batch mosaic generation with 2000px width, M density
    func testBatchGeneration2000pxM() async throws {
        try await runBatchGenerationTest(
            width: 2000,
            density: .m,
            testName: "2000px_M"
        )
    }

    /// Test batch mosaic generation with 2000px width, S density
    func testBatchGeneration2000pxS() async throws {
        try await runBatchGenerationTest(
            width: 2000,
            density: .s,
            testName: "2000px_S"
        )
    }

    /// Test batch mosaic generation with 2000px width, XS density
    func testBatchGeneration2000pxXS() async throws {
        try await runBatchGenerationTest(
            width: 2000,
            density: .xs,
            testName: "2000px_XS"
        )
    }

    /// Test batch mosaic generation with 5000px width, XXL density
    func testBatchGeneration5000pxXXL() async throws {
        try await runBatchGenerationTest(
            width: 5000,
            density: .xxl,
            testName: "5000px_XXL"
        )
    }

    /// Test batch mosaic generation with 5000px width, M density
    func testBatchGeneration5000pxM() async throws {
        try await runBatchGenerationTest(
            width: 5000,
            density: .m,
            testName: "5000px_M"
        )
    }

    /// Test batch mosaic generation with 5000px width, S density
    func testBatchGeneration5000pxS() async throws {
        try await runBatchGenerationTest(
            width: 5000,
            density: .s,
            testName: "5000px_S"
        )
    }

    /// Test batch mosaic generation with 5000px width, XS density
    func testBatchGeneration5000pxXS() async throws {
        try await runBatchGenerationTest(
            width: 5000,
            density: .xs,
            testName: "5000px_XS"
        )
    }

    // MARK: - Helper Methods

    /// Run batch generation test with specified parameters
    /// - Parameters:
    ///   - width: Mosaic width in pixels
    ///   - density: Density configuration
    ///   - testName: Name for the test (used in output filenames)
    private func runBatchGenerationTest(
        width: Int,
        density: DensityConfig,
        testName: String
    ) async throws {
        print("\n" + String(repeating: "=", count: 80))
        print("🎬 Starting Batch Generation Test: \(testName)")
        print(String(repeating: "=", count: 80))
        print("Configuration:")
        print("  • Width: \(width)px")
        print("  • Density: \(density.name)")
        print("  • Aspect Ratio: 16:9")
        print("  • Format: HEIF @ 40% quality")
        print("  • Accurate Timestamps: false")
        print("  • Include Metadata: true")
        print("  • Output: \(outputDirectory.path)")
        print(String(repeating: "-", count: 80))

        // Step 1: Load video inputs
        print("\n📹 Loading video inputs...")
        var videos: [VideoInput] = []
        for (index, urlString) in testVideoURLs.enumerated() {
            guard let url = URL(string: urlString) else {
                print("⚠️  Skipping invalid URL: \(urlString)")
                continue
            }

            do {
                print("  [\(index + 1)/\(testVideoURLs.count)] Loading: \(url.lastPathComponent)")
                let video = try await VideoInput(from: url)
                videos.append(video)
                print("    ✓ Duration: \(video.duration ?? 0)s, Resolution: \(Int(video.width ?? 0))x\(Int(video.height ?? 0))")
            } catch {
                print("    ✗ Failed: \(error.localizedDescription)")
            }
        }

        XCTAssertFalse(videos.isEmpty, "Should have loaded at least one video")
        print("\n✅ Loaded \(videos.count) videos successfully")

        // Step 2: Create configuration
        let config = MosaicConfiguration(
            width: width,
            density: density,
            format: .heif,
            layout: .init(
                aspectRatio: .widescreen,  // Force 16:9 aspect ratio
                useCustomLayout: true
            ),
            includeMetadata: true,
            useAccurateTimestamps: false,
            compressionQuality: 0.40,  // 40% quality
            ourputdirectory: outputDirectory
        )

        print("\n⚙️  Configuration created")
        print("  • Layout Algorithm: Custom")
        print("  • Target Aspect Ratio: 16:9")
        print("  • Output Format: HEIF")
        print("  • Quality: 40%")

        // Step 3: Create coordinator and generate mosaics
        print("\n🚀 Starting batch generation...")
        let context = try createModelContext()
        // Note: Using nonisolated(unsafe) context for testing purposes
        let coordinator = MosaicGeneratorCoordinator(
            modelContext: context,
            concurrencyLimit: 4
        )

        let startTime = Date()

        let results = try await coordinator.generateMosaicsforbatch(
            videos: videos,
            config: config
        ) { progressInfo in
            let percentage = Int(progressInfo.progress * 100)
            let elapsed = Date().timeIntervalSince(startTime)

            print("  📊 Progress: \(percentage)% - Elapsed: \(String(format: "%.1fs", elapsed))")
            print("    → Processing: \(progressInfo.video.title)")
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Step 4: Verify results
        print("\n" + String(repeating: "-", count: 80))
        print("📊 RESULTS")
        print(String(repeating: "-", count: 80))

        XCTAssertEqual(results.count, videos.count, "Should have results for all videos")

        var successCount = 0
        var failureCount = 0
        var totalFileSize: Int64 = 0

        for (index, result) in results.enumerated() {
            print("\n[\(index + 1)/\(results.count)] \(result.video.title)")

            if result.isSuccess {
                successCount += 1

                if let url = result.outputURL {
                    print("  ✅ SUCCESS")
                    print("    • Output: \(url.lastPathComponent)")

                    // Verify file exists
                    let fileManager = FileManager.default
                    XCTAssertTrue(fileManager.fileExists(atPath: url.path), "Output file should exist")

                    // Get file size
                    if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                       let fileSize = attributes[FileAttributeKey.size] as? Int64 {
                        totalFileSize += fileSize
                        let fileSizeMB = Double(fileSize) / 1_048_576
                        print("    • Size: \(String(format: "%.2f MB", fileSizeMB))")
                    }
                } else {
                    print("  ⚠️  Success but no output URL")
                }
            } else {
                failureCount += 1
                print("  ❌ FAILED")
                if let error = result.error {
                    print("    • Error: \(error.localizedDescription)")
                }
            }
        }

        // Step 5: Print summary
        print("\n" + String(repeating: "=", count: 80))
        print("📈 SUMMARY - \(testName)")
        print(String(repeating: "=", count: 80))
        print("Videos Processed: \(results.count)")
        print("  ✅ Successful: \(successCount)")
        print("  ❌ Failed: \(failureCount)")
        print("\nPerformance:")
        print("  • Total Time: \(String(format: "%.2fs", totalTime))")
        print("  • Average Time per Video: \(String(format: "%.2fs", totalTime / Double(results.count)))")
        print("  • Total Output Size: \(String(format: "%.2f MB", Double(totalFileSize) / 1_048_576))")
        print("  • Average Output Size: \(String(format: "%.2f MB", Double(totalFileSize) / 1_048_576 / Double(successCount)))")
        print("\nConfiguration:")
        print("  • Width: \(width)px")
        print("  • Density: \(density.name)")
        print("  • Aspect Ratio: 16:9")
        print("  • Format: HEIF @ 40%")
        print(String(repeating: "=", count: 80) + "\n")

        // Verify at least one success
        XCTAssertGreaterThan(successCount, 0, "Should have at least one successful generation")
    }

    // MARK: - Performance Tests

    /// Performance test for batch generation
    func testBatchGenerationPerformance() async throws {
        print("\n⚡️ Running Performance Test...")
        try await runBatchGenerationTest(
            width: 1000,
            density: .s,
            testName: "Performance"
        )
    }
}

// MARK: - Test Helpers

@available(macOS 15, iOS 18, *)
extension BatchMosaicGenerationTests {

    /// Helper to format file size
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Helper to format duration
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
