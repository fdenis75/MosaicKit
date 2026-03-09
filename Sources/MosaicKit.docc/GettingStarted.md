# Getting Started with MosaicKit

Learn how to integrate MosaicKit into your project and generate your first video mosaic.

@Metadata {
    @PageImage(purpose: card, source: "mosaic-hero")
}

## Overview

MosaicKit makes it easy to create beautiful video mosaics with just a few lines of code. This guide will walk you through installation, basic usage, and your first mosaic generation.

## Installation

### Swift Package Manager

Add MosaicKit to your project using Swift Package Manager:

1. In Xcode, select **File → Add Package Dependencies**
2. Enter the repository URL: `https://github.com/fdenis75/MosaicKit`
3. Select the version you want to use
4. Click **Add Package**

Alternatively, add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/fdenis75/MosaicKit.git", from: "1.0.0")
]
```

## Platform Requirements

- **macOS 15.0+** (uses Metal GPU acceleration by default)
- **iOS 15.0+** (uses Core Graphics with vImage optimization)
- **Swift 6.2+**

## Basic Usage

### Single Video Mosaic

Generate a mosaic from a single video file:

```swift
import MosaicKit

// 1. Create a generator (auto-selects best implementation)
let generator = try MosaicGenerator()

// 2. Configure the mosaic
let config = MosaicConfiguration.default

// 3. Generate the mosaic
let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
let outputDir = URL(fileURLWithPath: "/path/to/output")

let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)

print("Mosaic saved to: \(mosaicURL.path)")
```

### Custom Configuration

Customize the mosaic appearance and settings:

```swift
let config = MosaicConfiguration(
    width: 5120,                           // Output width in pixels
    density: .xl,                          // Frame extraction density
    format: .heif,                         // Output format (HEIF, JPEG, PNG)
    layout: LayoutConfiguration(
        aspectRatio: .widescreen,          // 16:9 aspect ratio
        layoutType: .custom                // Use custom layout algorithm
    ),
    includeMetadata: true,                 // Include metadata header
    compressionQuality: 0.8                // High quality output
)

let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)
```

### Batch Processing

Generate mosaics for multiple videos:

```swift
let videoURLs = [url1, url2, url3, url4, url5]

let mosaicURLs = try await generator.generateBatch(
    from: videoURLs,
    config: config,
    outputDirectory: outputDir
) { completed, total in
    print("Progress: \(completed)/\(total) videos processed")
}

print("Generated \(mosaicURLs.count) mosaics")
```

## Choosing a Generator Implementation

MosaicKit automatically selects the best generator for your platform, but you can override this:

```swift
// Automatic selection (recommended)
let generator = try MosaicGenerator()

// Force Core Graphics on macOS (useful for testing iOS behavior)
let cgGenerator = try MosaicGenerator(preference: .preferCoreGraphics)

// Prefer Metal (macOS only, falls back to Core Graphics on iOS)
let metalGenerator = try MosaicGenerator(preference: .preferMetal)
```

### When to Choose Core Graphics on macOS

- Testing iOS behavior without an iOS device
- Systems without adequate GPU resources
- Environments where Metal is unavailable
- Comparing performance between implementations

## Understanding Density Levels

Density controls how many frames are extracted from your video:

| Density | Description | Use Case |
|---------|-------------|----------|
| `.xxl` | Minimal frames | Quick previews, very long videos |
| `.xl` | Low density | Long videos, fast processing |
| `.l` | Medium density | Balanced quality and speed |
| `.m` | High density (default) | Best quality for most videos |
| `.s` | Very high density | Short videos, maximum detail |
| `.xs` | Super high density | Very short clips |
| `.xxs` | Maximal frames | Maximum possible detail |

```swift
// Quick preview with fewer frames
let quickConfig = MosaicConfiguration(density: .xxl)

// Maximum detail with many frames
let detailedConfig = MosaicConfiguration(density: .xxs)
```

## Layout Types

MosaicKit supports multiple layout algorithms:

```swift
// Custom layout - three-zone layout with centered large thumbnails
let customLayout = LayoutConfiguration(layoutType: .custom)

// Classic layout - traditional grid arrangement
let classicLayout = LayoutConfiguration(layoutType: .classic)

// Auto layout - adapts to screen size
let autoLayout = LayoutConfiguration(layoutType: .auto)

// Dynamic layout - center-emphasized with variable sizes
let dynamicLayout = LayoutConfiguration(layoutType: .dynamic)

// iPhone layout - optimized for vertical scrolling
let iphoneLayout = LayoutConfiguration(layoutType: .iphone)
```

See <doc:LayoutAlgorithms> for detailed comparison of each layout type.

## Output Formats

Choose the best output format for your needs:

```swift
// HEIF - Best compression, smallest file size (recommended)
let heifConfig = MosaicConfiguration(format: .heif)

// JPEG - Universal compatibility
let jpegConfig = MosaicConfiguration(format: .jpeg)

// PNG - Lossless, larger file size
let pngConfig = MosaicConfiguration(format: .png)
```

## Overlay & Annotations

All visual decorations are configured through `MosaicConfiguration.overlay`, an ``OverlayConfiguration`` value that groups four subsystems. Every property defaults to the original hardcoded appearance so no migration is required.

### Per-Frame Labels

```swift
config.overlay.frameLabel = FrameLabelConfig(
    show:            true,
    format:          .timestamp,     // .timestamp | .frameIndex | .none
    position:        .bottomRight,   // five anchor positions
    textColor:       MosaicColor(red: 1, green: 1, blue: 1),
    backgroundStyle: .pill           // .pill | .none | .fullWidth
)
```

### Metadata Header Band

Shown only when `includeMetadata` is `true`. Choose which fields appear and in what order:

```swift
config.overlay.header = HeaderConfig(
    fields: [
        .title, .duration, .fileSize, .resolution, .codec, .bitrate,
        .frameRate, .filePath,
        .colorPalette(swatchCount: 8),                    // colour swatches row
        .custom(label: "Director", value: "Jane Doe")     // arbitrary key/value
    ],
    height:          .fixed(80),   // or .auto (50% of first thumbnail row)
    textColor:       nil,          // nil → platform default
    backgroundColor: nil           // nil → semi-transparent dark default
)
```

### Watermark

```swift
// Text watermark
config.overlay.watermark = WatermarkConfig(
    content:  .text("© Studio 2025"),
    position: .bottomRight,   // .topLeft | .topRight | .bottomLeft | .bottomRight | .center
    opacity:  0.35,           // 0.0–1.0 (clamped)
    scale:    0.12            // fraction of mosaic width (clamped to 0.01–1.0)
)

// Image watermark (loaded from a local file)
config.overlay.watermark = WatermarkConfig(
    content:  .image(URL(fileURLWithPath: "/path/to/logo.png")),
    position: .topLeft,
    opacity:  0.5,
    scale:    0.08
)
```

### Color DNA Strip

A thin band where each column shows the dominant colour of one frame — a MovieBarcode-style visualisation:

```swift
config.overlay.colorDNA = ColorDNAConfig(
    show:     true,
    height:   24,          // pixels (clamped to minimum 8)
    position: .bottom,     // .top | .bottom
    style:    .gradient    // .barcode (hard columns) | .gradient (smooth transition)
)
```

### Full Annotation Example

```swift
config.includeMetadata = true
config.overlay = OverlayConfiguration(
    frameLabel: FrameLabelConfig(
        format: .timestamp, position: .bottomRight, backgroundStyle: .pill
    ),
    header: HeaderConfig(
        fields: [.title, .duration, .resolution, .colorPalette(swatchCount: 8)],
        height: .fixed(80)
    ),
    watermark: WatermarkConfig(
        content: .text("© My Studio"), position: .bottomRight, opacity: 0.35, scale: 0.10
    ),
    colorDNA: ColorDNAConfig(show: true, height: 24, position: .bottom, style: .gradient)
)
```

## Error Handling

MosaicKit provides comprehensive error types:

```swift
do {
    let mosaicURL = try await generator.generate(
        from: videoURL,
        config: config,
        outputDirectory: outputDir
    )
} catch MosaicError.invalidVideo(let message) {
    print("Invalid video: \(message)")
} catch MosaicError.metalNotSupported {
    print("Metal not available, falling back to Core Graphics")
    let cgGenerator = try MosaicGenerator(preference: .preferCoreGraphics)
    // Retry with Core Graphics...
} catch {
    print("Generation failed: \(error.localizedDescription)")
}
```

## Next Steps

Now that you've created your first mosaic, explore these topics:

- <doc:Architecture> - Understanding the dual-platform architecture
- <doc:LayoutAlgorithms> - Deep dive into layout algorithms
- <doc:PerformanceGuide> - Optimization strategies for large batches
- <doc:CustomLayouts> - Creating custom layout configurations

## See Also

- ``MosaicGenerator``
- ``MosaicConfiguration``
- ``DensityConfig``
- ``LayoutConfiguration``
- ``OverlayConfiguration``
- ``FrameLabelConfig``
- ``HeaderConfig``
- ``WatermarkConfig``
- ``ColorDNAConfig``
