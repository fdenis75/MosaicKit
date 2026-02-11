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
        
     
        
        
        videoURL = URL(fileURLWithPath: "/Users/francois/Dev/Packages/MosaicKit/MosaicKit/nata.mp4")
        guard videoURL.startAccessingSecurityScopedResource() else {
         throw fatalError()
        }
        outputDirectory = videoURL.deletingLastPathComponent().appendingPathComponent("PreviewTests_\(UUID().uuidString)")
        mosaicOutputDirectory = videoURL.deletingLastPathComponent().appendingPathComponent("MosaicTests_\(UUID().uuidString)")
        
        if videoURL.startAccessingSecurityScopedResource() {
            // Copy to temp directory
      /*            let tempVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_video_copy.mp4")
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
            
                let durations: [TimeInterval] = [30]
            let densities: [DensityConfig] = [.m]
            let usenativeTools: [Bool] = [false]
            let nativePresets: [nativeExportPreset] = [nativeExportPreset.AVAssetExportPresetHEVC1920x1080]
            let sjsPresets: [SjSExportPreset] = [SjSExportPreset.hevc , SjSExportPreset.h264_HighAutoLevel]
            let sjsRes: [ExportMaxResolution] = ExportMaxResolution.allCases
        //    let qualities: [Double] = [V]
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
                
                struct RunResult {
                    let mode: String // "Native" or "SJS"
                    let targetDuration: TimeInterval
                    let density: DensityConfig
                    let presetLabel: String
                    let elapsed: TimeInterval
                    let sizeMB: Double
                    let actualDuration: Double
                }
                var results: [RunResult] = []
                
                var config: PreviewConfiguration?
                for duration in durations {
                    for density in densities {
                        for resolution in sjsRes {
                            
                            for usenativeTool in usenativeTools {
                                if usenativeTool {
                                    for nativePreset in nativePresets {
                                        config = PreviewConfiguration(
                                            targetDuration: duration,
                                            density: density,
                                            format: .mp4,
                                            includeAudio: true,
                                            outputDirectory: outputDirectory,
                                            fullPathInName: false,
                                            useNativeExport: usenativeTool,
                                            exportPresetName: nativePreset,
                                            maxResolution: resolution
                                        )
                                        
                                        print("\n--------------------------------------------------")
                                        print("test:🧪 Testing Configuration:")
                                        print("test:  - Target Duration: \(duration)s")
                                        
                                        // Ensure config is set before use
                                        guard let config = config else {
                                            Issue.record("Configuration was not initialized for duration=\(duration), density=\(density), useNative=\(usenativeTool)")
                                            continue
                                        }
                                        
                                        print(config.debugDescription)
                                        
                                        
                                        
                                        do {
                                            let startTime = Date()
                                            
                                            let outputURL = try await coordinator.generatePreview(for: videoInput, config: config) { progress in
                                                // Track progress if needed
                                                //      sleep(5)
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
                                            
                                            // Basic validation of the generated file
                                            let asset = AVURLAsset(url: outputURL)
                                            let actualCMTime = try await asset.load(.duration)
                                            let actualSeconds = CMTimeGetSeconds(actualCMTime)
                                            print("test:  - Actual Duration: \(actualSeconds)s")
                                            
                                            results.append(RunResult(
                                                mode: "Native",
                                                targetDuration: duration,
                                                density: density,
                                                presetLabel: nativePreset.rawValue,
                                                elapsed: elapsed,
                                                sizeMB: fileSizeMB,
                                                actualDuration: actualSeconds
                                            ))
                                            
                                            successCount += 1
                                            
                                        } catch {
                                            print("❌ Failed: \(error.localizedDescription)")
                                            failureCount += 1
                                            // Don't fail the whole test, just log it, so we can see which combinations fail
                                            // Issue.record("Generation failed for config: \(config)")
                                        }
                                    }
                                } else
                                {
                                    for sjsPreset in sjsPresets {
                                            config = PreviewConfiguration(
                                                targetDuration: duration,
                                                density: density,
                                                format: .mp4,
                                                includeAudio: true,
                                                outputDirectory: outputDirectory,
                                                fullPathInName: false,
                                                useNativeExport: usenativeTool,
                                                sjSExportPresetName: sjsPreset,
                                                maxResolution: resolution
                                            )
                                            
                                            print("\n--------------------------------------------------")
                                            print("test:🧪 Testing Configuration:")
                                            print("test:  - Target Duration: \(duration)s")
                                            
                                            // Ensure config is set before use
                                            guard let config = config else {
                                                Issue.record("Configuration was not initialized for duration=\(duration), density=\(density), useNative=\(usenativeTool)")
                                                continue
                                            }
                                            
                                            print(config.debugDescription)
                                            
                                            
                                            
                                            do {
                                                let startTime = Date()
                                                
                                                let outputURL = try await coordinator.generatePreview(for: videoInput, config: config) { progress in
                                                    // Track progress if needed
                                                    //                                            sleep(5)
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
                                                
                                                let asset = AVURLAsset(url: outputURL)
                                                let actualCMTime = try await asset.load(.duration)
                                                let actualSeconds = CMTimeGetSeconds(actualCMTime)
                                                print("test  - Actual Duration: \(actualSeconds)s")
                                                
                                                results.append(RunResult(
                                                    mode: "SJS",
                                                    targetDuration: duration,
                                                    density: density,
                                                    presetLabel: "\(sjsPreset.rawValue)-\(sjsRes)",
                                                    elapsed: elapsed,
                                                    sizeMB: fileSizeMB,
                                                    actualDuration: actualSeconds
                                                ))
                                                
                                                successCount += 1
                                                
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
                    }
                }
                
                print("\n==================================================")
                print("Test Summary")
         //       print("Total Combinations: \(durations.count * densities.count * qualities.count)")
                print("Success: \(successCount)")
                print("Failures: \(failureCount)")
                print("==================================================")
                
                print("\nComparison Summary (Native vs SJS)")
                struct GroupKey: Hashable {
                    let target: Int
                    let densityName: String
                }
                let grouped = Dictionary(grouping: results) { (r: RunResult) in
                    GroupKey(target: Int(r.targetDuration), densityName: r.density.name)
                }
                for key in grouped.keys.sorted(by: { lhs, rhs in
                    if lhs.target == rhs.target { return lhs.densityName < rhs.densityName }
                    return lhs.target < rhs.target
                }) {
                    guard let bucket = grouped[key] else { continue }
                    let target = key.target
                    let densityName = key.densityName
                    let natives = bucket.filter { $0.mode == "Native" }
                    let sjses = bucket.filter { $0.mode == "SJS" }
                    print("\n— Target: \(target)s, Density: \(densityName)")
                    print(String(format: "%@", "Mode   | Preset                  | ActDur(s) | Time(s)     | Size(MB)   "))
                    func pad(_ s: String, _ to: Int) -> String { let count = s.count; return s + String(repeating: " ", count: max(0, to - count)) }
                    func line(_ r: RunResult) -> String {
                        let mode = pad(r.mode, 6)
                        let preset = pad(r.presetLabel, 22)
                        let act = String(format: "%-10.1f", r.actualDuration)
                        let time = String(format: "%-12.2f", r.elapsed)
                        let size = String(format: "%-12.2f", r.sizeMB)
                        return "\(mode) | \(preset) | \(act) | \(time) | \(size)"
                    }
                    for r in natives { print(line(r)) }
                    for r in sjses { print(line(r)) }
                }
                
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

