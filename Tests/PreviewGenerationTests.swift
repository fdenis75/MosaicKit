import XCTest
@testable import MosaicKit
import AVFoundation

@available(macOS 15, iOS 18, *)
final class PreviewGenerationTests: XCTestCase {
    
    var videoURL: URL!
    var outputDirectory: URL!
    
    override func setUp() async throws {
        // Use the test video provided by the user
        let originalURL = URL(fileURLWithPath: "/Volumes/Ext-6TB-2/0002025/11/20/Ciren&Mag.mp4")
        
        // Copy to temp directory
        let tempVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_video_copy.mp4")
        if FileManager.default.fileExists(atPath: tempVideoURL.path) {
            try FileManager.default.removeItem(at: tempVideoURL)
        }
        try FileManager.default.copyItem(at: originalURL, to: tempVideoURL)
        videoURL = tempVideoURL
        
        // Create a temporary directory for outputs
        outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        // Verify video exists
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw XCTSkip("Test video not found at \(videoURL.path)")
        }
    }
    
    override func tearDown() async throws {
        // Cleanup outputs
    //    if let outputDirectory = outputDirectory, FileManager.default.fileExists(atPath: outputDirectory.path) {
      //      try? FileManager.default.removeItem(at: outputDirectory)
       // }
    }
    
    func testPreviewGenerationWithVariations() async throws {
        let durations: [TimeInterval] = [120]
        let densities: [DensityConfig] = [.s]
        let qualities: [Double] = [1.0, 0.75, 0.5, 0.25, 0.1]
        
        let videoInput = try await VideoInput(from: videoURL)
        
        // DEBUG: Try loading tracks here
        print("DEBUG: Test - loading tracks directly")
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        print("DEBUG: Test - tracks loaded: \(tracks.count)")
        
        let generator = PreviewVideoGenerator()
        
        print("🎬 Starting Preview Generation Tests")
        print("Input Video: \(videoInput.title)")
        print("Duration: \(videoInput.duration ?? 0)s")
        
        var successCount = 0
        var failureCount = 0
        
        for duration in durations {
            for density in densities {
                for quality in qualities {
                    print("\n--------------------------------------------------")
                    print("test:🧪 Testing Configuration:")
                    print("test:  - Target Duration: \(duration)s")
                    print("test:  - Density: \(density.name)")
                    print("test:  - Quality: \(quality)")
                    
                    let config = PreviewConfiguration(
                        targetDuration: duration,
                        density: density,
                        format: .mp4,
                        includeAudio: false,
                        outputDirectory: outputDirectory,
                        fullPathInName: false,
                        compressionQuality: quality
                    )
                    
                    do {
                        let startTime = Date()
                        let outputURL = try await generator.generate(for: videoInput, config: config)
                        let elapsed = Date().timeIntervalSince(startTime)
                        
                        // Verify file exists and has size
                        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        let fileSizeMB = Double(fileSize) / 1_048_576.0
                        
                        print("test: ✅ Success!")
                        print("test:  - Output: \(outputURL.path)")
                        print("test:  - Time: \(String(format: "%.2f", elapsed))s")
                        print("test:  - Size: \(String(format: "%.2f", fileSizeMB)) MB")
                        
                        successCount += 1
                        
                        // Basic validation of the generated file
                        let asset = AVURLAsset(url: outputURL)
                        let duration = try await asset.load(.duration)
                        print("  - Actual Duration: \(CMTimeGetSeconds(duration))s")
                        
                    } catch {
                        print("❌ Failed: \(error.localizedDescription)")
                        failureCount += 1
                        // Don't fail the whole test, just log it, so we can see which combinations fail
                        // XCTFail("Generation failed for config: \(config)") 
                    }
                }
            }
        }
        
        print("\n==================================================")
        print("Test Summary")
        print("Total Combinations: \(durations.count * densities.count * qualities.count)")
        print("Success: \(successCount)")
        print("Failures: \(failureCount)")
        print("==================================================")
        
        XCTAssertEqual(failureCount, 0, "Some preview generations failed")
    }
}
