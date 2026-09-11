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
    .package(url: "https://github.com/fdenis75/MosaicKit.git", from: "1.6.0")
]
```

Link the `MosaicKit` product for mosaic and preview generation. If you also need `.webp` /
`.heic`-animated output, additionally link the separate `MosaicKitWebP` product and call
`MosaicKitWebP.register()` once at startup (before generating any WebP output) — it's kept
out of the main `MosaicKit` product because it's the only thing in the dependency graph that
pulls in a binary xcframework (`webp.swift` → `libwebp-ios`), which otherwise breaks Xcode
SwiftUI Preview's JIT execution for every client, even ones that never touch WebP:

```swift
dependencies: [
    .product(name: "MosaicKit", package: "MosaicKit"),
    .product(name: "MosaicKitWebP", package: "MosaicKit")  // only if you need .webp output
]
```

```swift
import MosaicKitWebP

MosaicKitWebP.register()
```

## Platform Requirements

- **macOS 26.0+**, **iOS 26.0+**, **macCatalyst 26.0+**
- **Swift 6.2+**
- A single Metal GPU engine (`MetalMosaicGenerator`) is used on every platform — there is no
  Core Graphics fallback or platform-selection wrapper.

## Basic Usage

### Single Video Mosaic

Generate a mosaic from a single video file:

```swift
import MosaicKit

// 1. Create a generator
let generator = try MetalMosaicGenerator()

// 2. Describe the source video
let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
let video = try await VideoInput(from: videoURL)

// 3. Configure and generate the mosaic
let config = MosaicConfiguration(outputdirectory: URL(fileURLWithPath: "/path/to/output"))
let mosaicURL = try await generator.generate(for: video, config: config)

print("Mosaic saved to: \(mosaicURL.path)")
```

### Custom Configuration

Customize the mosaic appearance and settings:

```swift
let config = MosaicConfiguration(
    width: 5120,                           // Output width in pixels
    density: .xl,                          // Frame extraction density
    format: .heif,                         // Output format (.heif, .jpeg, .png, .webp)
    layout: LayoutConfiguration(
        aspectRatio: .widescreen,          // 16:9 aspect ratio
        layoutType: .custom                // Use custom layout algorithm
    ),
    includeMetadata: true,                 // Include metadata header
    compressionQuality: 0.8,               // High quality output
    outputdirectory: outputDir
)

let mosaicURL = try await generator.generate(for: video, config: config)
```

### Batch Processing

Generate mosaics for multiple videos concurrently with `MosaicGeneratorCoordinator`:

```swift
var videos: [VideoInput] = []
for url in [url1, url2, url3, url4, url5] {
    videos.append(try await VideoInput(from: url))
}

let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 4)

let results = try await coordinator.generateMosaicsforbatch(
    videos: videos,
    config: config
) { progress in
    print("Progress: \(progress)")
}

print("Generated \(results.count) mosaics")
```

`scanVideos(in:recursive:)` builds a `[VideoInput]` from every video file in a directory if you'd
rather not construct `VideoInput` values by hand:

```swift
let videos = await scanVideos(in: URL(fileURLWithPath: "/path/to/folder"), recursive: true)
```

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
    height:          .fixed(80),   // or .auto (fit rendered content)
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

## Output Path Control

### Skip existing files

Both `MosaicConfiguration` and `PreviewConfiguration` expose an `overwrite` flag (default `false`). When `false`, the generator checks for the output file before doing any work and returns the existing URL immediately if it is already present — ideal for incremental batch runs.

```swift
var config = MosaicConfiguration()
config.overwrite = false   // skip if already generated (default)
config.overwrite = true    // always regenerate
```

### Disabling the output subdirectory

`MosaicConfiguration` creates a subdirectory inside the output directory before saving a mosaic
(the resolved `outputDirectoryTemplate`, or a `{configurationHash}` folder by default). Set
`createOutputSubdirectory = false` to save mosaics directly into the output directory instead:

```swift
config.createOutputSubdirectory = false   // no subdirectory; outputDirectoryTemplate is ignored
```

### Custom directory and filename templates

Use token strings to fully control where output files are placed and how they are named:

```swift
// Group by density, then a date/time-stamped run folder
config.outputDirectoryTemplate = "{root}/{density}/{date}_{time}"

// Name each file with density and date
config.filenameTemplate = "{name}_{density}_{date}.{ext}"
```

Available tokens for `MosaicConfiguration`: `{root}`, `{service}`, `{creator}`, `{hash}`, `{width}`, `{density}`, `{aspectRatio}`, `{layout}`, `{date}`, `{time}` (directory); `{name}`, `{ext}`, `{width}`, `{density}`, `{aspectRatio}`, `{layout}`, `{hash}`, `{service}`, `{creator}`, `{postID}`, `{date}` (filename).

Available tokens for `PreviewConfiguration`: `{root}`, `{duration}`, `{density}`, `{format}`, `{date}` (directory); `{name}`, `{ext}`, `{duration}`, `{density}`, `{format}`, `{audio}`, `{date}` (filename).

When either template is `nil` (the default), the existing naming logic is used unchanged.

## Error Handling

MosaicKit provides comprehensive error types:

```swift
do {
    let generator = try MetalMosaicGenerator()
    let mosaicURL = try await generator.generate(for: video, config: config)
} catch MetalProcessorError.deviceNotAvailable {
    // No usable Metal device — there is no Core Graphics fallback to retry with.
    print("Metal is not supported on this device")
} catch MosaicError.invalidVideo(let message) {
    print("Invalid video: \(message)")
} catch {
    print("Generation failed: \(error.localizedDescription)")
}
```

## Next Steps

Now that you've created your first mosaic, explore these topics:

- <doc:Architecture> - Understanding the Metal-based architecture
- <doc:LayoutAlgorithms> - Deep dive into layout algorithms
- <doc:PerformanceGuide> - Optimization strategies for large batches
- <doc:PreviewExporting> - Generating condensed preview videos
- <doc:BackgroundProcessing> - Running generation from an iOS background task

## See Also

- ``MetalMosaicGenerator``
- ``MosaicGeneratorCoordinator``
- ``MosaicConfiguration``
- ``PreviewConfiguration``
- ``DensityConfig``
- ``LayoutConfiguration``
- ``OverlayConfiguration``
- ``FrameLabelConfig``
- ``HeaderConfig``
- ``WatermarkConfig``
- ``ColorDNAConfig``
