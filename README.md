# MosaicKit

A high-performance Swift package for generating video mosaics with Metal-accelerated image processing. Extract frames from videos and arrange them into beautiful, customizable mosaic layouts with optional metadata headers.

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20%7C%20iOS%2026%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- 🚀 **Metal-Accelerated Processing** - Hardware-accelerated mosaic generation for maximum performance
- 🎨 **Multiple Layout Algorithms** - Classic, custom, auto-screen, dynamic, and iPhone-optimized layouts
- ⚙️ **Configurable Density Levels** - From XXL (minimal) to XXS (maximal) frame extraction
- 📦 **Multiple Output Formats** - JPEG, PNG, and HEIF with configurable compression
- 🔄 **Batch Processing** - Intelligent concurrency management for processing multiple videos
- 🎯 **Hardware-Accelerated Frame Extraction** - Uses VideoToolbox for optimal performance
- 📊 **Metadata Headers** - Optional metadata overlay with video information

## Requirements

- macOS 15.0+ or iOS 15.0+
- Xcode 26.0+
- Swift 6.2+
- Metal-capable device

## Installation

### Swift Package Manager

Add MosaicKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/fdenis75/MosaicKit.git", from: "1.0.0")
]
```

Then add it to your target dependencies:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["MosaicKit"]
    )
]
```

### Xcode

1. Go to **File → Add Package Dependencies...**
2. Enter the repository URL
3. Select the version you want to use
4. Click **Add Package**

## Quick Start

### Simple API (Recommended)

```swift
import MosaicKit

// Simple one-step generation
let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
let outputDir = URL(fileURLWithPath: "/path/to/output")

let generator = try MosaicGenerator()
let config = MosaicConfiguration.default

let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)

print("Mosaic saved to: \(mosaicURL.path)")
```

### Advanced Usage (Direct Access)

For more control, use `MetalMosaicGenerator` directly:

```swift
import MosaicKit

// Create a video input from a file URL
let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
let video = try await VideoInput(from: videoURL)

// Configure mosaic settings
var config = MosaicConfiguration.default
config.width = 5000
config.density = .m
config.format = .heif
config.outputdirectory = URL(fileURLWithPath: "/path/to/output")

// Generate the mosaic
let generator = try MetalMosaicGenerator()
let mosaicURL = try await generator.generate(
    for: video,
    config: config
)

print("Mosaic saved to: \(mosaicURL.path)")
```

## Configuration Options

### MosaicConfiguration

```swift
public struct MosaicConfiguration {
    var width: Int                      // Output width (default: 5120)
    var density: DensityConfig          // Frame density (default: .m)
    var format: OutputFormat            // JPEG, PNG, or HEIF
    var layout: LayoutConfiguration     // Layout settings
    var includeMetadata: Bool           // Add metadata header
    var useAccurateTimestamps: Bool     // Precise frame extraction
    var compressionQuality: Double      // 0.0 to 1.0 (default: 0.4)
    var outputdirectory: URL?           // Output directory
}
```

### Density Levels

Control the number of frames extracted from your video:

```swift
// Fewer frames (faster processing, smaller file)
config.density = .xxl  // Minimal - ~25% of base calculation
config.density = .xl   // Low - ~50% of base calculation
config.density = .l    // Medium - ~75% of base calculation

// More frames (slower processing, larger file, more detail)
config.density = .m    // High (default) - 100% of base calculation
config.density = .s    // Very high - 200% of base calculation
config.density = .xs   // Super high - 300% of base calculation
config.density = .xxs  // Maximal - 400% of base calculation
```

### Layout Options

Choose from multiple layout algorithms:

```swift
var layout = LayoutConfiguration()

// Aspect ratios
layout.aspectRatio = .widescreen  // 16:9
layout.aspectRatio = .standard    // 4:3
layout.aspectRatio = .square      // 1:1
layout.aspectRatio = .ultrawide   // 21:9
layout.aspectRatio = .vertical    // 9:16 (portrait)

// Layout modes
layout.useCustomLayout = true     // Three-zone layout with large center thumbnails
layout.useAutoLayout = true       // Adapt to screen size
// Or use classic grid layout (default)

// Visual settings
layout.visual.addBorder = true
layout.visual.borderColor = .white
layout.visual.borderWidth = 2.0
layout.visual.addShadow = true
```

### Output Formats

```swift
// HEIF - Best compression, smaller file size (recommended)
config.format = .heif
config.compressionQuality = 0.4

// JPEG - Good compression, universal compatibility
config.format = .jpeg
config.compressionQuality = 0.8

// PNG - Lossless, larger file size
config.format = .png
```

## Advanced Usage

### Batch Processing

Process multiple videos with intelligent concurrency:

```swift
let generator = try MetalMosaicGenerator()
let coordinator = MosaicGeneratorCoordinator(
    mosaicGenerator: generator,
    concurrencyLimit: 4
)

let videos: [VideoInput] = [video1, video2, video3]

let results = try await coordinator.generateMosaicsforbatch(
    videos: videos,
    config: config
) { progress in
    print("Video: \(progress.video.title)")
    print("Progress: \(Int(progress.progress * 100))%")
    print("Status: \(progress.status)")
}

// Check results
for result in results {
    if result.isSuccess {
        print("✅ Success: \(result.outputURL?.path ?? "unknown")")
    } else {
        print("❌ Failed: \(result.error?.localizedDescription ?? "unknown")")
    }
}
```

### Progress Tracking

Monitor generation progress in real-time using `MosaicGeneratorCoordinator`:

```swift
let result = try await coordinator.generateMosaic(
    for: video,
    config: config
) { progress in
    // progress.progress is 0.0–1.0
    // progress.status indicates the current phase
    print("Progress: \(Int(progress.progress * 100))% - \(progress.status)")
}
```

### Custom Video Input

Create VideoInput manually with specific metadata:

```swift
let video = VideoInput(
    url: videoURL,
    title: "My Video",
    duration: 120.0,
    width: 1920,
    height: 1080,
    frameRate: 30.0,
    fileSize: 50_000_000,
    metadata: VideoMetadata(
        codec: "H.264",
        bitrate: 5_000_000
    )
)
```

### Performance Metrics

Track generator performance:

```swift
let metrics = await generator.getPerformanceMetrics()
print("Average generation time: \(metrics["averageGenerationTime"] ?? 0)")
print("Total generations: \(metrics["generationCount"] ?? 0)")
```

### Cancellation

Cancel ongoing operations:

```swift
// Cancel specific video
await generator.cancel(for: video)

// Cancel all operations
await generator.cancelAll()

// Or cancel batch operations
await coordinator.cancelAllGenerations()
```

## Layout Algorithm Details

### Custom Layout (Recommended)

Three-zone layout with small thumbnails at top/bottom and large thumbnails in the center:

```swift
config.layout.useCustomLayout = true
// Automatically calculates optimal grid based on:
// - Target aspect ratio
// - Video aspect ratio
// - Thumbnail count
// - Density settings
```

### Classic Layout

Traditional grid layout with uniform thumbnail sizes:

```swift
config.layout.useCustomLayout = false
config.layout.useAutoLayout = false
// Simple rows × columns grid
```

### Auto Layout

Adapts to your display size for optimal viewing:

```swift
config.layout.useAutoLayout = true
// Calculates based on:
// - Screen resolution
// - DPI/scaling factor
// - Minimum readable thumbnail size
```

### Dynamic Layout

Center-emphasized layout with variable thumbnail sizes:

```swift
config.layout.useDynamicLayout = true
// Larger thumbnails in center, smaller at edges
```

## Examples

### Example 1: High-Quality Mosaic

```swift
var config = MosaicConfiguration(
    width: 10000,
    density: .xs,
    format: .heif,
    layout: .default,
    includeMetadata: true,
    useAccurateTimestamps: true,
    compressionQuality: 0.6
)
config.outputdirectory = outputDir

let mosaicURL = try await generator.generate(for: video, config: config)
```

### Example 2: Fast Preview Mosaic

```swift
var config = MosaicConfiguration(
    width: 2000,
    density: .xl,
    format: .jpeg,
    layout: .default,
    includeMetadata: false,
    useAccurateTimestamps: false,
    compressionQuality: 0.4
)
config.outputdirectory = outputDir

let mosaicURL = try await generator.generate(for: video, config: config)
```

### Example 3: Square Social Media Mosaic

```swift
var config = MosaicConfiguration.default
config.width = 3000
config.layout.aspectRatio = .square
config.density = .m
config.format = .jpeg
config.compressionQuality = 0.8
config.outputdirectory = outputDir

let mosaicURL = try await generator.generate(for: video, config: config)
```

## Performance Tips

1. **Use HEIF format** - Best compression with good quality
2. **Start with medium density** - Adjust based on video length
3. **Disable accurate timestamps** for faster processing when precision isn't critical
4. **Use batch processing** for multiple videos to leverage concurrency
5. **Consider screen size** - Match output width to your display for optimal viewing
6. **Monitor memory usage** - Very high densities or large widths can use significant memory

## Frame Extraction Strategy

MosaicKit uses an intelligent frame extraction strategy:

- **Skips** first 5% and last 5% of video (avoid fade in/out)
- **First third**: 20% of frames (opening scenes)
- **Middle third**: 60% of frames (main content)
- **Last third**: 20% of frames (ending)
- **Hardware accelerated** using VideoToolbox
- **Concurrent extraction** based on available CPU cores

## Error Handling

```swift
do {
    let mosaicURL = try await generator.generate(for: video, config: config)
} catch MosaicError.metalNotSupported {
    print("Metal is not available on this device")
} catch MosaicError.invalidVideo(let message) {
    print("Invalid video: \(message)")
} catch MosaicError.layoutCreationFailed(let error) {
    print("Layout creation failed: \(error)")
} catch MosaicError.saveFailed(let url, let error) {
    print("Failed to save mosaic to \(url): \(error)")
} catch {
    print("Unexpected error: \(error)")
}
```

## System Requirements for Best Performance

- **Apple Silicon (M1/M2/M3)** - Optimal performance with unified memory
- **16GB+ RAM** - For processing large videos or high densities
- **Intel Mac with dedicated GPU** - Good performance with AMD/NVIDIA GPUs
- **Fast SSD** - For quick frame extraction and mosaic saving

## Concurrency Management

Batch processing automatically adjusts concurrency based on:

- **CPU cores**: max(2, processorCount - 1)
- **Available memory**: max(2, physicalMemory / 4GB)
- **Final limit**: min(cpu_limit, memory_limit, configured_limit)

```swift
// Configure custom concurrency limit
let generator = try MetalMosaicGenerator()
let coordinator = MosaicGeneratorCoordinator(
    mosaicGenerator: generator,
    concurrencyLimit: 8  // Max 8 videos processed simultaneously
)
```

## Troubleshooting

### "Metal is not supported"
- Ensure you're running on a Metal-capable device
- Check minimum OS requirements (macOS 15+ / iOS 15+)

### Out of memory errors
- Reduce mosaic width
- Lower density setting
- Process videos in smaller batches
- Close other applications

### Slow processing
- Check if accurate timestamps are needed (slower but more precise)
- Verify Metal is being used (check device capabilities)
- Consider reducing frame count for long videos
- Use batch processing for multiple videos

### Quality issues
- Increase compression quality (0.6-0.8 for HEIF/JPEG)
- Use higher density settings
- Increase output width
- Try PNG format for lossless output

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Built with Swift 6's modern concurrency features
- Uses Metal for GPU-accelerated processing
- VideoToolbox for hardware-accelerated frame extraction
- [swift-log](https://github.com/apple/swift-log) for structured logging
- [DominantColors](https://github.com/DenDmitriev/DominantColors) for color analysis

## Support

For issues, questions, or feature requests, please open an issue on GitHub.
