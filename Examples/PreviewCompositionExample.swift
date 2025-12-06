//
//  PreviewCompositionExample.swift
//  MosaicKit
//
//  Example demonstrating how to generate a preview composition for video player playback
//

import Foundation
import AVFoundation
import MosaicKit

@available(macOS 26, iOS 26, *)
func generatePreviewComposition() async throws {
    // 1. Set up video input
    let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")
    let video = try await VideoInput(from: videoURL)

    // 2. Configure preview settings
    let config = PreviewConfiguration(
        targetDuration: 60,        // 1 minute preview
        density: .m,                // Medium density (16 segments)
        format: .mp4,               // Output format (not used for composition)
        includeAudio: true,         // Include audio in preview
        compressionQuality: 0.8     // High quality (not used for composition)
    )

    // 3. Create preview generator
    let generator = PreviewVideoGenerator()

    // 4. Set up progress handler (optional)
    await generator.setProgressHandler(for: video) { progress in
        print("Progress: \(Int(progress.progress * 100))% - \(progress.status.displayLabel)")
        if let message = progress.message {
            print("  \(message)")
        }
    }

    // 5. Generate composition (without exporting to file)
    print("Generating preview composition...")
    let playerItem = try await generator.generateComposition(for: video, config: config)

    // 6. Use the composition with AVPlayer
    let player = AVPlayer(playerItem: playerItem)

    // 7. Set up player observers (optional)
    observePlayerStatus(player: player)

    // 8. Play the preview
    print("Playing preview...")
    player.play()

    // Keep the program running to allow playback
    // In a real app, this would be managed by your UI framework
    try await Task.sleep(for: .seconds(60))
}

@available(macOS 26, iOS 26, *)
func observePlayerStatus(player: AVPlayer) {
    // Observe player status
    player.addObserver(
        NSObject(),
        forKeyPath: #keyPath(AVPlayer.status),
        options: [.new, .initial],
        context: nil
    )

    // You can also observe the current time
    player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 1, preferredTimescale: 1),
        queue: .main
    ) { time in
        let currentSeconds = CMTimeGetSeconds(time)
        print("Current playback time: \(Int(currentSeconds))s")
    }
}

// MARK: - Example Usage Scenarios

@available(macOS 26, iOS 26, *)
func exampleWithCustomConfiguration() async throws {
    let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
    let video = try await VideoInput(from: videoURL)

    // High-density, short preview (30 seconds with many segments)
    let shortConfig = PreviewConfiguration(
        targetDuration: 30,
        density: .xs,               // Extra small = 32 segments
        includeAudio: false         // Silent preview
    )

    let generator = PreviewVideoGenerator()
    let playerItem = try await generator.generateComposition(for: video, config: shortConfig)

    // Create player and configure
    let player = AVPlayer(playerItem: playerItem)
    player.volume = 0.0  // Muted since we disabled audio
    player.play()
}

@available(macOS 26, iOS 26, *)
func exampleWithLoop() async throws {
    let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
    let video = try await VideoInput(from: videoURL)

    let config = PreviewConfiguration(targetDuration: 60, density: .m)
    let generator = PreviewVideoGenerator()
    let playerItem = try await generator.generateComposition(for: video, config: config)

    let player = AVPlayer(playerItem: playerItem)

    // Loop the preview
    NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: playerItem,
        queue: .main
    ) { _ in
        player.seek(to: .zero)
        player.play()
    }

    player.play()
}

// MARK: - Comparison: Export vs Composition

@available(macOS 26, iOS 26, *)
func compareExportVsComposition() async throws {
    let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
    let video = try await VideoInput(from: videoURL)
    let config = PreviewConfiguration(targetDuration: 60, density: .m)
    let generator = PreviewVideoGenerator()

    // Method 1: Export to file (traditional)
    print("Method 1: Exporting to file...")
    let startExport = Date()
    let exportedURL = try await generator.generate(for: video, config: config)
    let exportTime = Date().timeIntervalSince(startExport)
    print("Export completed in \(exportTime)s")
    print("File saved at: \(exportedURL.path)")

    // Method 2: Generate composition (new feature)
    print("\nMethod 2: Generating composition...")
    let startComposition = Date()
    let playerItem = try await generator.generateComposition(for: video, config: config)
    let compositionTime = Date().timeIntervalSince(startComposition)
    print("Composition completed in \(compositionTime)s")

    // Composition is faster because it skips the export step
    print("\nTime saved: \(exportTime - compositionTime)s")

    // Use the composition for immediate playback
    let player = AVPlayer(playerItem: playerItem)
    player.play()
}

// MARK: - Main Entry Point

@available(macOS 26, iOS 26, *)
@main
struct PreviewCompositionApp {
    static func main() async throws {
        print("=== MosaicKit Preview Composition Example ===\n")

        // Run the basic example
        try await generatePreviewComposition()

        print("\n=== Example Complete ===")
    }
}
