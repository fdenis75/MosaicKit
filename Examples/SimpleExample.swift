import Foundation
import MosaicKit

/// Minimal single-video example using MosaicKit's public actor API.
@main
struct SimpleExample {
    static func main() async throws {
        let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")
        let outputDirectory = URL(fileURLWithPath: "/path/to/output")
        let source = try await VideoInput(from: videoURL)

        var configuration = MosaicConfiguration.default
        configuration.outputdirectory = outputDirectory

        let generator = try MetalMosaicGenerator()
        let outputURL = try await generator.generate(for: source, config: configuration)
        print("Mosaic saved to: \(outputURL.path)")
    }
}

// Reusable snippets for custom configurations and batches.
enum SimpleSnippets {
    static func custom() async throws -> URL {
        let source = try await VideoInput(from: URL(fileURLWithPath: "/path/to/video.mp4"))
        var configuration = MosaicConfiguration(width: 4000, density: .m, format: .heif)
        configuration.outputdirectory = URL(fileURLWithPath: "/path/to/output")
        return try await MetalMosaicGenerator().generate(for: source, config: configuration)
    }

    static func batch() async throws -> [MosaicGenerationResult] {
        let urls = [URL(fileURLWithPath: "/path/to/video1.mp4"), URL(fileURLWithPath: "/path/to/video2.mp4")]
        let videos = try await urls.asyncMap { try await VideoInput(from: $0) }
        let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 2)
        return try await coordinator.generateMosaicsforbatch(videos: videos, config: .default) { progress in
            print("\(progress.video.title): \(Int(progress.progress * 100))%")
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
