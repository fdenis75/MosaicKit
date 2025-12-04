# Quick Start Tutorial

Generate your first video mosaic in 5 minutes.

## What You'll Build

By the end of this tutorial, you'll have:
- Generated a mosaic from a sample video
- Customized the appearance and layout
- Compared different density and layout options

## Prerequisites

- Xcode 15.0+
- macOS 26.0+ or iOS 26.0+
- A video file to test with (any common format: MP4, MOV, M4V)

## Step 1: Add MosaicKit to Your Project

Add MosaicKit via Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/yourusername/MosaicKit", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies**

## Step 2: Import and Create a Generator

```swift
import MosaicKit

// Create a generator (auto-selects best implementation for your platform)
let generator = try MosaicGenerator()
```

## Step 3: Generate Your First Mosaic

```swift
// Path to your video file
let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")

// Output directory
let outputDir = URL(fileURLWithPath: "/path/to/output")

// Use default configuration
let config = MosaicConfiguration.default

// Generate the mosaic
let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)

print("Mosaic saved to: \(mosaicURL.path)")
```

## Step 4: Customize the Mosaic

### Adjust Density

```swift
// Quick preview with fewer frames
let quickConfig = MosaicConfiguration(density: .xl)
let quickMosaic = try await generator.generate(
    from: videoURL,
    config: quickConfig,
    outputDirectory: outputDir
)

// Maximum detail with more frames
let detailedConfig = MosaicConfiguration(density: .xxs)
let detailedMosaic = try await generator.generate(
    from: videoURL,
    config: detailedConfig,
    outputDirectory: outputDir
)
```

### Change Layout

```swift
// Try different layout types
let customLayout = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .custom)
)

let classicLayout = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .classic)
)

let dynamicLayout = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .dynamic)
)
```

### Adjust Output Size

```swift
// Mobile-sized mosaic
let mobileConfig = MosaicConfiguration(width: 2048)

// 5K mosaic for large displays
let largeConfig = MosaicConfiguration(width: 5120)
```

## Step 5: Complete Example

Here's a complete working example:

```swift
import Foundation
import MosaicKit

@main
struct MosaicApp {
    static func main() async throws {
        // 1. Create generator
        let generator = try MosaicGenerator()
        
        // 2. Configure mosaic
        let config = MosaicConfiguration(
            width: 4000,                    // 4K width
            density: .m,                    // High density
            format: .heif,                  // HEIF format
            layout: LayoutConfiguration(
                aspectRatio: .widescreen,   // 16:9
                layoutType: .custom         // Custom layout
            ),
            includeMetadata: true,          // Include header
            compressionQuality: 0.8         // High quality
        )
        
        // 3. Generate mosaic
        let videoURL = URL(fileURLWithPath: "/Users/you/Videos/sample.mp4")
        let outputDir = URL(fileURLWithPath: "/Users/you/Output")
        
        print("Generating mosaic...")
        let startTime = ContinuousClock.now
        
        let mosaicURL = try await generator.generate(
            from: videoURL,
            config: config,
            outputDirectory: outputDir
        )
        
        let duration = startTime.duration(to: .now)
        print("✅ Mosaic generated in \(duration)")
        print("📍 Saved to: \(mosaicURL.path)")
    }
}
```

## Step 6: Generate Multiple Mosaics

Process multiple videos at once:

```swift
let videoURLs = [
    URL(fileURLWithPath: "/path/to/video1.mp4"),
    URL(fileURLWithPath: "/path/to/video2.mp4"),
    URL(fileURLWithPath: "/path/to/video3.mp4")
]

let mosaicURLs = try await generator.generateBatch(
    from: videoURLs,
    config: config,
    outputDirectory: outputDir
) { completed, total in
    print("Progress: \(completed)/\(total)")
}

print("Generated \(mosaicURLs.count) mosaics")
```

## Next Steps

Now that you've created your first mosaics, explore:

- <doc:GettingStarted> - Comprehensive getting started guide
- <doc:LayoutAlgorithms> - Deep dive into layout options
- <doc:PerformanceGuide> - Optimization tips
- <doc:Architecture> - Understanding how MosaicKit works

## Common Issues

### Video Not Found

```swift
// Ensure the file exists
let fileManager = FileManager.default
guard fileManager.fileExists(atPath: videoURL.path) else {
    print("Video file not found!")
    return
}
```

### Output Directory Doesn't Exist

```swift
// Create output directory if needed
let outputDir = URL(fileURLWithPath: "/path/to/output")
try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
```

### Metal Not Available

```swift
// Fall back to Core Graphics
do {
    let generator = try MosaicGenerator(preference: .preferMetal)
} catch MosaicError.metalNotSupported {
    print("Metal not available, using Core Graphics")
    let generator = try MosaicGenerator(preference: .preferCoreGraphics)
}
```

## See Also

- ``MosaicGenerator``
- ``MosaicConfiguration``
- ``DensityConfig``
- ``LayoutConfiguration``
