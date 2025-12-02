//
//  TestMetal.swift
//  MosaicKit
//
import Testing
@testable import MosaicKit
import Foundation
import CoreGraphics
import ImageIO

/// Performance comparison tests between Metal and Core Graphics implementations
//@available(macOS 26, iOS 26, *)
struct TestMetal : ~Copyable {
    
    // MARK: - Properties
    
    let videoPath = "/Volumes/Ext-6TB-2/0002025/11/04/Kristy Black.mp4"
    let baseOutputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitTests", isDirectory: true)
    let metalOutputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitTests/Metal", isDirectory: true)
    let coreGraphicsOutputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitTests/CoreGraphics", isDirectory: true)
    
    // MARK: - Setup & Teardown
    
   init() throws {
        // Create output directories
        try FileManager.default.createDirectory(at: metalOutputDirectory, withIntermediateDirectories: true)
        //   try FileManager.default.createDirectory(at: coreGraphicsOutputDirectory, withIntermediateDirectories: true)

        print("\n📁 Output directories:")
        print("  Metal:         \(metalOutputDirectory.path)")
        //  print("  Core Graphics: \(coreGraphicsOutputDirectory.path)")

        // Verify video file exists
        let videoURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            struct TestError: Error {
                let message: String
            }
            throw TestError(message: "Video file not found at: \(videoPath)")
        }
    }

    deinit {
        // Keep generated mosaics for inspection
        // Uncomment to clean up:
        // try? FileManager.default.removeItem(at: baseOutputDirectory)

        print("\n✅ Mosaics saved to:")
        print("  open \(metalOutputDirectory.path)")
        //  print("  open \(coreGraphicsOutputDirectory.path)")
    }
    
    // MARK: - Comparison Tests
    
    /// Compare Metal vs Core Graphics for large mosaic (10000px width, High density)
    @Test func testLargeMosaicComparison() async throws {
        print("\n" + String(repeating: "=", count: 80))
        print("🔬 Large Mosaic Performance Comparison Test")
        print("Video: \(videoPath)")
        print(String(repeating: "=", count: 80))
        
        let videoURL = URL(fileURLWithPath: videoPath)
        
        // Configuration for large mosaic
        let config = MosaicConfiguration(
            width: 10000,
            density: .xs,
            format: .heif,
            layout: .default,
            includeMetadata: true,
            useAccurateTimestamps: true,
            compressionQuality: 0.8
        )
        
        // Test Metal implementation
        print("\n📊 Testing Metal Implementation...")
        let metalResults = try await runGeneratorTest(
            preference: .preferMetal,
            config: config,
            videoURL: videoURL,
            label: "Metal"
        )
       
        // Print comparison results
        
        // Verify both succeeded
        try #require(metalResults.outputURL, "Metal generation should succeed")
        
        // Verify both files exist
        if let metalURL = metalResults.outputURL {
            #expect(FileManager.default.fileExists(atPath: metalURL.path), "Metal output should exist")
        }
     
    }
    // MARK: - Helper Methods

    /// Run a single generator test and return results
    func runGeneratorTest(
        preference: MosaicGeneratorFactory.GeneratorPreference,
        config: MosaicConfiguration,
        videoURL: URL,
        label: String
    ) async throws -> TestResults {

        // Select output directory based on preference
        let outputDir: URL
        switch preference {
        case .preferMetal, .auto:
            outputDir = metalOutputDirectory
        case .preferCoreGraphics:
            outputDir = coreGraphicsOutputDirectory
        }

        var updatedConfig = config
        updatedConfig.outputdirectory = outputDir

        let startTime = Date()

        // Create generator
        let generator = try MosaicGenerator(preference: preference)
        let generatorCreationTime = Date().timeIntervalSince(startTime)

        // Track progress
        var progressUpdates: [Double] = []

        // Generate mosaic
        let generationStartTime = Date()
        let mosaicURL = try await generator.generate(
            from: videoURL,
            config: updatedConfig,
            outputDirectory: outputDir
        )
        let generationTime = Date().timeIntervalSince(generationStartTime)
        let totalTime = Date().timeIntervalSince(startTime)

        // Get file size
        let fileSize = try FileManager.default.attributesOfItem(atPath: mosaicURL.path)[.size] as? Int64 ?? 0
        let fileSizeMB = Double(fileSize) / 1_048_576.0

        // Get image dimensions
        guard let imageSource = CGImageSourceCreateWithURL(mosaicURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            struct TestError: Error {
                let message: String
            }
            throw TestError(message: "Failed to read image properties")
        }

        return TestResults(
            preference: preference,
            label: label,
            outputURL: mosaicURL,
            generatorCreationTime: generatorCreationTime,
            generationTime: generationTime,
            totalTime: totalTime,
            fileSize: fileSize,
            fileSizeMB: fileSizeMB,
            dimensions: (width, height),
            progressUpdates: progressUpdates
        )
    }

    /// Print comparison results in a nice format
    func printComparisonResults(metal: TestResults, coreGraphics: TestResults) {
        print("\n" + String(repeating: "─", count: 80))
        print("📊 PERFORMANCE COMPARISON RESULTS")
        print(String(repeating: "─", count: 80))

        // Timing comparison
        print("\n⏱️  TIMING:")
        print("  Metal:")
        print("    • Generator Creation: \(String(format: "%.3f", metal.generatorCreationTime))s")
        print("    • Mosaic Generation:  \(String(format: "%.3f", metal.generationTime))s")
        print("    • Total Time:         \(String(format: "%.3f", metal.totalTime))s")

        print("\n  Core Graphics:")
        print("    • Generator Creation: \(String(format: "%.3f", coreGraphics.generatorCreationTime))s")
        print("    • Mosaic Generation:  \(String(format: "%.3f", coreGraphics.generationTime))s")
        print("    • Total Time:         \(String(format: "%.3f", coreGraphics.totalTime))s")

        // Speed comparison
        let speedDiff = ((metal.generationTime - coreGraphics.generationTime) / coreGraphics.generationTime) * 100
        let faster = speedDiff < 0 ? "Metal" : "Core Graphics"
        let speedPercent = abs(speedDiff)
        print("\n  ⚡️ Speed Winner: \(faster) is \(String(format: "%.1f", speedPercent))% faster")

        // Output comparison
        print("\n📦 OUTPUT:")
        print("  Metal:")
        print("    • File Size:     \(String(format: "%.2f", metal.fileSizeMB)) MB")
        print("    • Dimensions:    \(metal.dimensions.0) × \(metal.dimensions.1)")
        print("    • File:          \(metal.outputURL?.lastPathComponent ?? "N/A")")
        if let url = metal.outputURL {
            print("    • Location:      \(url.deletingLastPathComponent().path)")
        }

        print("\n  Core Graphics:")
        print("    • File Size:     \(String(format: "%.2f", coreGraphics.fileSizeMB)) MB")
        print("    • Dimensions:    \(coreGraphics.dimensions.0) × \(coreGraphics.dimensions.1)")
        print("    • File:          \(coreGraphics.outputURL?.lastPathComponent ?? "N/A")")
        if let url = coreGraphics.outputURL {
            print("    • Location:      \(url.deletingLastPathComponent().path)")
        }

        // File size comparison
        let sizeDiff = ((metal.fileSizeMB - coreGraphics.fileSizeMB) / coreGraphics.fileSizeMB) * 100
        let smaller = sizeDiff < 0 ? "Metal" : "Core Graphics"
        print("\n  💾 Size: \(smaller) output is \(String(format: "%.1f", abs(sizeDiff)))% smaller")

        // Efficiency metrics
        print("\n⚙️  EFFICIENCY:")
        let metalPixelsPerSecond = Double(metal.dimensions.0 * metal.dimensions.1) / metal.generationTime
        let cgPixelsPerSecond = Double(coreGraphics.dimensions.0 * coreGraphics.dimensions.1) / coreGraphics.generationTime

        print("  Metal:         \(String(format: "%.0f", metalPixelsPerSecond / 1_000_000)) million pixels/sec")
        print("  Core Graphics: \(String(format: "%.0f", cgPixelsPerSecond / 1_000_000)) million pixels/sec")

        print("\n" + String(repeating: "─", count: 80) + "\n")
    }

    // MARK: - Test Results Structure

    struct TestResults {
        let preference: MosaicGeneratorFactory.GeneratorPreference
        let label: String
        let outputURL: URL?
        let generatorCreationTime: TimeInterval
        let generationTime: TimeInterval
        let totalTime: TimeInterval
        let fileSize: Int64
        let fileSizeMB: Double
        let dimensions: (width: Int, height: Int)
        let progressUpdates: [Double]
    }
}

