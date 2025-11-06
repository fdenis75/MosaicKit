import MosaicKit
import Foundation
import SwiftData

/// Example of batch processing multiple videos
@available(macOS 15, iOS 18, *)
struct BatchExample {

    static func run() async throws {
        print("🎬 MosaicKit - Batch Processing Example")
        print("=" * 50)

        // 1. Setup
        let videoURLs = [
            URL(fileURLWithPath: "/path/to/video1.mp4"),
            URL(fileURLWithPath: "/path/to/video2.mp4"),
            URL(fileURLWithPath: "/path/to/video3.mp4")
        ]
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        // 2. Create video inputs
        print("\n📹 Loading \(videoURLs.count) videos...")
        var videos: [VideoInput] = []
        for (index, url) in videoURLs.enumerated() {
            do {
                let video = try await VideoInput(from: url)
                videos.append(video)
                print("   [\(index + 1)/\(videoURLs.count)] ✓ \(video.title)")
            } catch {
                print("   [\(index + 1)/\(videoURLs.count)] ✗ Failed: \(error.localizedDescription)")
            }
        }

        guard !videos.isEmpty else {
            print("\n❌ No valid videos to process")
            return
        }

        // 3. Configure
        print("\n⚙️  Configuration:")
        var config = MosaicConfiguration(
            width: 4000,
            density: .m,
            format: .heif,
            compressionQuality: 0.4
        )
        config.outputdirectory = outputDir
        print("   Width: \(config.width)px")
        print("   Density: \(config.density.name)")
        print("   Concurrent limit: 4")

        // 4. Setup coordinator
        // Note: You'll need to provide a ModelContext
        // This is just an example structure
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema([]), configurations: modelConfig)
        let context = ModelContext(container)

        let coordinator = MosaicGeneratorCoordinator(
            modelContext: context,
            concurrencyLimit: 4
        )

        // 5. Process with progress tracking
        print("\n🎨 Generating mosaics...")
        print("─" * 50)

        var statusMessages: [UUID: String] = [:]
        let startTime = Date()

        let results = try await coordinator.generateMosaicsforbatch(
            videos: videos,
            config: config
        ) { progress in
            let percentage = Int(progress.progress * 100)
            let statusEmoji: String

            switch progress.status {
            case .queued:
                statusEmoji = "⏳"
            case .inProgress:
                statusEmoji = "⚙️"
            case .completed:
                statusEmoji = "✅"
            case .failed:
                statusEmoji = "❌"
            case .cancelled:
                statusEmoji = "🚫"
            }

            let message = "\(statusEmoji) \(progress.video.title): \(percentage)%"

            // Only print if status changed
            if statusMessages[progress.video.id] != message {
                statusMessages[progress.video.id] = message
                print("   \(message)")
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)

        // 6. Display results
        print("─" * 50)
        print("\n📊 Results:")

        let successful = results.filter { $0.isSuccess }
        let failed = results.filter { !$0.isSuccess }

        print("\n✅ Successful: \(successful.count)")
        for result in successful {
            if let url = result.outputURL {
                print("   • \(result.video.title)")
                print("     → \(url.path)")
            }
        }

        if !failed.isEmpty {
            print("\n❌ Failed: \(failed.count)")
            for result in failed {
                print("   • \(result.video.title)")
                if let error = result.error {
                    print("     Error: \(error.localizedDescription)")
                }
            }
        }

        print("\n⏱  Total time: \(String(format: "%.1f", elapsed))s")
        print("   Average: \(String(format: "%.1f", elapsed / Double(videos.count)))s per video")

        print("\n" + "=" * 50)
        print("🎉 Batch processing complete!")
    }
}
