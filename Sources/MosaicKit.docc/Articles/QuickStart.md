# Quick Start Tutorial

Generate your first video mosaic in 5 minutes.

## What You'll Build

By the end of this tutorial, you'll have:
- Generated a mosaic from a sample video
- Customized the appearance and layout
- Compared different density and layout options

## Prerequisites

- Xcode 26.0+
- Swift 6.2+
- macOS 26.0+, iOS 26.0+, or macCatalyst 26.0+
- A video file to test with (any common format: MP4, MOV, M4V)

## Step 1: Add MosaicKit to Your Project

Add MosaicKit via Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/fdenis75/MosaicKit.git", from: "1.6.0")
]
```

Or in Xcode: **File → Add Package Dependencies**

## Step 2: Import and Create a Generator

```swift
import MosaicKit

// Construct the Metal engine directly — there's no factory or platform switch.
let generator = try MetalMosaicGenerator()
```

## Step 3: Generate Your First Mosaic

```swift
// Path to your video file
let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")

// Output directory
let outputDir = URL(fileURLWithPath: "/path/to/output")

// Describe the source video and use a default configuration
let video = try await VideoInput(from: videoURL)
let config = MosaicConfiguration(outputdirectory: outputDir)

// Generate the mosaic
let mosaicURL = try await generator.generate(for: video, config: config)

print("Mosaic saved to: \(mosaicURL.path)")
```

## Step 4: Customize the Mosaic

### Adjust Density

```swift
// Quick preview with fewer frames
let quickConfig = MosaicConfiguration(density: .xl, outputdirectory: outputDir)
let quickMosaic = try await generator.generate(for: video, config: quickConfig)

// Maximum detail with more frames
let detailedConfig = MosaicConfiguration(density: .xxs, outputdirectory: outputDir)
let detailedMosaic = try await generator.generate(for: video, config: detailedConfig)
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

### Add Overlay Annotations

Decorate thumbnails and the assembled mosaic with labels, a metadata header, a watermark, and a Color DNA strip — all through `MosaicConfiguration.overlay`:

```swift
var annotated = MosaicConfiguration(width: 5120, density: .m, format: .heif, includeMetadata: true)

// Per-frame timestamp label (bottom-right pill, white text)
annotated.overlay.frameLabel = FrameLabelConfig(
    format: .timestamp, position: .bottomRight, backgroundStyle: .pill
)

// Metadata header with six fields + a colour-palette row
annotated.overlay.header = HeaderConfig(
    fields: [.title, .duration, .resolution, .codec, .bitrate, .colorPalette(swatchCount: 8)],
    height: .fixed(80)
)

// Translucent text watermark in the bottom-right corner
annotated.overlay.watermark = WatermarkConfig(
    content: .text("© My Studio"), position: .bottomRight, opacity: 0.35, scale: 0.10
)

// Gradient Color DNA strip under the mosaic
annotated.overlay.colorDNA = ColorDNAConfig(show: true, height: 24, position: .bottom, style: .gradient)
```

## Step 5: Complete Example

Here's a complete working example:

```swift
import Foundation
import MosaicKit

@main
struct MosaicApp {
    static func main() async throws {
        let videoURL = URL(fileURLWithPath: "/Users/you/Videos/sample.mp4")
        let outputDir = URL(fileURLWithPath: "/Users/you/Output")

        // 1. Create generator and describe the source video
        let generator = try MetalMosaicGenerator()
        let video = try await VideoInput(from: videoURL)

        // 2. Configure mosaic
        let config = MosaicConfiguration(
            width: 4000,                    // 4K width
            density: .m,                    // Default density
            format: .heif,                  // HEIF format
            layout: LayoutConfiguration(
                aspectRatio: .widescreen,   // 16:9
                layoutType: .custom         // Custom layout
            ),
            includeMetadata: true,          // Include header
            compressionQuality: 0.8,        // High quality
            outputdirectory: outputDir
        )

        // 3. Generate mosaic
        print("Generating mosaic...")
        let startTime = ContinuousClock.now

        let mosaicURL = try await generator.generate(for: video, config: config)

        let duration = startTime.duration(to: .now)
        print("✅ Mosaic generated in \(duration)")
        print("📍 Saved to: \(mosaicURL.path)")
    }
}
```

## Step 6: Generate Multiple Mosaics

Process multiple videos concurrently with ``MosaicGeneratorCoordinator``:

```swift
let videoURLs = [
    URL(fileURLWithPath: "/path/to/video1.mp4"),
    URL(fileURLWithPath: "/path/to/video2.mp4"),
    URL(fileURLWithPath: "/path/to/video3.mp4")
]

var videos: [VideoInput] = []
for url in videoURLs {
    videos.append(try await VideoInput(from: url))
}

let coordinator = try createDefaultMosaicCoordinator()

let results = try await coordinator.generateMosaicsforbatch(
    videos: videos,
    config: config
) { progress in
    print("Progress: \(progress)")
}

print("Generated \(results.count) mosaics")
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

There's no Core Graphics fallback — MosaicKit is Metal-only on every platform it targets. A missing
device throws at generator construction time:

```swift
do {
    let generator = try MetalMosaicGenerator()
} catch MetalProcessorError.deviceNotAvailable {
    print("No usable Metal device on this system")
}
```

## See Also

- ``MetalMosaicGenerator``
- ``MosaicGeneratorCoordinator``
- ``MosaicConfiguration``
- ``DensityConfig``
- ``LayoutConfiguration``
- ``OverlayConfiguration``
- ``FrameLabelConfig``
- ``HeaderConfig``
- ``WatermarkConfig``
- ``ColorDNAConfig``
