import Testing
@testable import MosaicKit
import AVFoundation
import Foundation
import CoreGraphics
import ImageIO
internal import Combine


//
@Suite("Preview and Mosaic Generation Tests")
struct PreviewGenerationTests {
    
    let videoURL: URL
    var outputDirectory: URL
    let mosaicOutputDirectory: URL
    /// Publishes updates to active generations
      // let progressPublisher = PassthroughSubject<[UUID: PreviewGenerationProgress], Never>()

       /// Active preview generations (video ID -> progress)
   
        

    init() async throws {
        // Use the test video provided by the user
        
     
        
        
        videoURL = URL(fileURLWithPath: "/Users/francois/Dev/Packages/MosaicKit/MosaicKit/Rollercoaster666MYM.mp4")
        guard videoURL.startAccessingSecurityScopedResource() else {
         throw fatalError()
        }
        outputDirectory = videoURL.deletingLastPathComponent().appendingPathComponent("PreviewTests_\(UUID().uuidString)")
        mosaicOutputDirectory = videoURL.deletingLastPathComponent().appendingPathComponent("MosaicTests_\(UUID().uuidString)")
        
        if videoURL.startAccessingSecurityScopedResource() {
            // Copy to temp directory
      /*      let tempVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_video_copy.mp4")
            if FileManager.default.fileExists(atPath: tempVideoURL.path) {
                try FileManager.default.removeItem(at: tempVideoURL)
            }
            try FileManager.default.copyItem(at: videoURL, to: tempVideoURL)*/
            
            
            // Create a temporary directory for outputs
            outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests_\(UUID().uuidString)")
            if outputDirectory.startAccessingSecurityScopedResource() {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                print("output directory: \(outputDirectory.absoluteString)")
                //      mosaicOutputDirectory = videoURL.deletingLastPathComponent().appendingPathComponent("MosaicTests_\(UUID().uuidString)")
                //        let didStartAccessing2 = mosaicOutputDirectory.startAccessingSecurityScopedResource()
                //   try FileManager.default.createDirectory(at: mosaicOutputDirectory, withIntermediateDirectories: true)
            } else {
                    outputDirectory.stopAccessingSecurityScopedResource()
                }
                // Verify video exists
                guard FileManager.default.fileExists(atPath: videoURL.path) else {
                    Issue.record("Test video not found at \(videoURL.path)")
                    throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video not found"])
                    
                }
            
        } else
        {
            videoURL.stopAccessingSecurityScopedResource()
        }
    }
        // Deinit is not strictly needed for cleanup in struct-based tests unless we want explicit teardown,
        // but Swift Testing handles teardown via `deinit` or simply letting the struct go out of scope.
        // However, since we created directories, we might want to clean them up.
        // Note: Structs don't have deinit. If we need teardown, we can use a class or just rely on OS temp cleanup.
        // For now, we'll leave cleanup out as it was commented out in the original code anyway.
        
        @Test("Preview Generation with Variations")
        func previewGenerationWithVariations() async throws {
            guard videoURL.startAccessingSecurityScopedResource() else {
             throw fatalError()
            }
            
                let durations: [TimeInterval] = [60]
                let densities: [DensityConfig] = [.xxl]
            let qualities: [Double] = [1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.1]
                //     let didStartAccessing = videoURL.startAccessingSecurityScopedResource()
                
                let videoInput = try await VideoInput(from: videoURL)
                
                // DEBUG: Try loading tracks here
                /*      print("DEBUG: Test - loading tracks directly")
                 let asset = AVURLAsset(url: videoURL)
                 let tracks = try await asset.loadTracks(withMediaType: .video)
                 print("DEBUG: Test - tracks loaded: \(tracks.count)")*/
            let coordinator = PreviewGeneratorCoordinator()
              //  let generator = PreviewVideoGenerator()
                
            print("🎬 Starting Preview Generation Tests")
                //    print("Input Video: \(videoInput.title)")
                //  print("Duration: \(videoInput.duration ?? 0)s")
                
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
                                
                                let outputURL = try await coordinator.generatePreview(for: videoInput, config: config) { progress in
                                    // Track progress if needed
                                    print("Progress: \(progress.status.displayLabel) - \(Int(progress.progress * 100))%")
                                }
                                
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
                                // Issue.record("Generation failed for config: \(config)")
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
                
                #expect(failureCount == 0, "Some preview generations failed")
           
        }
    
    @Test("Mosaic Generation with Variations")
    func mosaicGenerationWithVariations() async throws {
       
        let videoInput = try await VideoInput(from: videoURL)
        let widths: [Int] = [5120]
        let densities: [DensityConfig] = [.m, .xxs, .xxl]
      //  let layouts: [LayoutType] = [.auto, .custom, .classic, .dynamic]
        let layouts: [LayoutType] = [.custom]
        let aspectRatios: [AspectRatio] = AspectRatio.allCases

        let generator = try MosaicGeneratorFactory.createGenerator(preference: .preferCoreGraphics)
        print("🎬 Starting mosaic Generation Tests")
        print("Input Video: \(videoInput.title)")
        var successCount = 0
        var failureCount = 0
        
        for width in widths {
            for density in densities {
                for layout in layouts {
                    for aspectRatio in aspectRatios {
                        print("\n--------------------------------------------------")
                        print("test:🧪 Testing Configuration:")
                        print("test:  - Width: \(width)")
                        print("test:  - Density: \(density.name)")
                        print("test:  - layout: \(layout)")
                        let layoutconfig = LayoutConfiguration(aspectRatio: aspectRatio, layoutType: layout)
                        
                        let config = MosaicConfiguration(
                            width: width,
                            density: density,
                            format: .heif,
                            layout: layoutconfig,
                            includeMetadata: true,
                            useAccurateTimestamps: false,
                            compressionQuality: 0.4,
                            outputdirectory: mosaicOutputDirectory.appendingPathComponent(layout.rawValue),
                            fullPathInName: false
                        )
                        
                        do {
                            let startTime = Date()
                            let outputURL = try await generator.generate(for: videoInput, config: config, forIphone: false)
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
                            //    let asset = AVURLAsset(url: outputURL)
                            //   let duration = try await asset.load(.duration)
                            //    print("  - Actual Duration: \(CMTimeGetSeconds(duration))s")
                            
                        } catch {
                            print("❌ Failed: \(error.localizedDescription)")
                            failureCount += 1
                            // Don't fail the whole test, just log it, so we can see which combinations fail
                            // Issue.record("Generation failed for config: \(config)")
                        }
                    }
                }
            }
        }
        print("\n==================================================")
        print("Test Summary")
        print("Total Combinations: \(widths.count * densities.count * layouts.count * aspectRatios.count)")
        print("Success: \(successCount)")
        print("Failures: \(failureCount)")
        print("==================================================")
        mosaicOutputDirectory.stopAccessingSecurityScopedResource()
        #expect(failureCount == 0, "Some preview generations failed")
    }
}
