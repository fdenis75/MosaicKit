# MosaicKit Quick Start Guide

Get up and running with MosaicKit in minutes.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/MosaicKit.git", from: "1.0.0")
]
```

## 5-Minute Tutorial

### Step 1: Import MosaicKit

```swift
import MosaicKit
import Foundation
```

### Step 2: Create a Video Input

```swift
// Option 1: From URL with automatic metadata extraction
let videoURL = URL(fileURLWithPath: "/Users/you/Movies/video.mp4")
let video = try await VideoInput(from: videoURL)

// Option 2: Provide metadata manually
let video = VideoInput(
    url: videoURL,
    title: "My Video",
    duration: 120.0
)
```

### Step 3: Configure Your Mosaic

```swift
var config = MosaicConfiguration.default
config.outputdirectory = URL(fileURLWithPath: "/Users/you/Desktop/Mosaics")

// Optional: Customize settings
config.width = 5000                    // Output width in pixels
config.density = .m                    // Frame density (xxl to xxs)
config.format = .heif                  // Output format
config.includeMetadata = true          // Add metadata header
config.compressionQuality = 0.4        // 0.0 = small file, 1.0 = high quality
```

### Step 4: Generate the Mosaic

```swift
// Simple API - Easiest way
let generator = try MosaicGenerator()
let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)

print("✅ Mosaic saved: \(mosaicURL.path)")

// Or use advanced API for more control
let advancedGenerator = try MetalMosaicGenerator()
let video = try await VideoInput(from: videoURL)
let mosaicURL2 = try await advancedGenerator.generate(
    for: video,
    config: config
)
```

## Complete Working Example

```swift
import MosaicKit
import Foundation

@main
struct MosaicApp {
    static func main() async throws {
        // 1. Setup
        let videoURL = URL(fileURLWithPath: "/path/to/video.mp4")
        let outputDir = URL(fileURLWithPath: "/path/to/output")

        // 2. Create video input
        print("📹 Loading video...")
        let video = try await VideoInput(from: videoURL)
        print("Duration: \(video.duration ?? 0)s")
        print("Resolution: \(video.width ?? 0)x\(video.height ?? 0)")

        // 3. Configure
        var config = MosaicConfiguration(
            width: 5000,
            density: .m,
            format: .heif,
            compressionQuality: 0.4
        )
        config.outputdirectory = outputDir

        // 4. Generate
        print("🎨 Generating mosaic...")
        let generator = try MetalMosaicGenerator()
        let mosaicURL = try await generator.generate(for: video, config: config)

        print("✅ Success! Mosaic saved to:")
        print(mosaicURL.path)
    }
}
```

## Common Use Cases

### Use Case 1: Quick Preview

Generate a fast, low-resolution preview:

```swift
var config = MosaicConfiguration(
    width: 2000,
    density: .xl,
    format: .jpeg,
    useAccurateTimestamps: false,
    compressionQuality: 0.4
)
config.outputdirectory = outputDir
```

### Use Case 2: High-Quality Archive

Generate a detailed, high-quality mosaic:

```swift
var config = MosaicConfiguration(
    width: 8000,
    density: .xs,
    format: .heif,
    useAccurateTimestamps: true,
    compressionQuality: 0.6
)
config.outputdirectory = outputDir
```

### Use Case 3: Social Media Post

Square format, optimized for Instagram/Facebook:

```swift
var config = MosaicConfiguration.default
config.width = 3000
config.layout.aspectRatio = .square
config.format = .jpeg
config.compressionQuality = 0.8
config.outputdirectory = outputDir
```

### Use Case 4: Batch Processing

Process multiple videos:

```swift
// Setup
let videos = [
    try await VideoInput(from: url1),
    try await VideoInput(from: url2),
    try await VideoInput(from: url3)
]

let coordinator = MosaicGeneratorCoordinator(
    modelContext: modelContext,
    concurrencyLimit: 4
)

// Process with progress tracking
let results = try await coordinator.generateMosaicsforbatch(
    videos: videos,
    config: config
) { progress in
    print("\(progress.video.title): \(Int(progress.progress * 100))%")
}

// Check results
for result in results {
    if result.isSuccess {
        print("✅ \(result.video.title)")
    } else {
        print("❌ \(result.video.title): \(result.error?.localizedDescription ?? "")")
    }
}
```

## Configuration Cheat Sheet

### Density Settings

| Setting | Frames | Use Case |
|---------|--------|----------|
| `.xxl` | Minimal | Ultra-fast preview |
| `.xl` | Low | Quick preview |
| `.l` | Medium | Standard preview |
| `.m` | High (default) | Balanced |
| `.s` | Very High | Detailed |
| `.xs` | Super High | Very detailed |
| `.xxs` | Maximal | Maximum detail |

### Output Formats

| Format | Pros | Cons | When to Use |
|--------|------|------|-------------|
| `.heif` | Best compression, smaller files | Newer format | Most cases (recommended) |
| `.jpeg` | Universal compatibility | Larger than HEIF | Sharing, compatibility |
| `.png` | Lossless | Large files | When quality is critical |

### Width Guidelines

| Width | Description | Use Case |
|-------|-------------|----------|
| 1200-2000 | Small | Mobile viewing, quick previews |
| 3000-5000 | Medium | Desktop viewing, standard use |
| 6000-8000 | Large | High-quality display, archival |
| 10000+ | Very Large | Professional use, printing |

## Pro Tips

### Tip 1: Start Small
Begin with lower settings and adjust:
```swift
config.width = 2000
config.density = .l
```

### Tip 2: Match Your Screen
Set width to match your display:
```swift
// For a 4K display
config.width = 3840
```

### Tip 3: Balance Quality vs Size
Adjust compression for your needs:
```swift
// Smaller files
config.compressionQuality = 0.3

// Better quality
config.compressionQuality = 0.7
```

### Tip 4: Use Custom Layouts
Get better-looking mosaics:
```swift
config.layout.useCustomLayout = true
config.layout.aspectRatio = .widescreen
```

### Tip 5: Track Progress
Show progress for better UX:
```swift
try await generator.generate(for: video, config: config) { progress in
    print("Progress: \(Int(progress * 100))%")
}
```

## Troubleshooting

### "Metal is not supported"
**Problem**: Device doesn't support Metal
**Solution**: Check device compatibility, minimum macOS 14/iOS 17

### Out of Memory
**Problem**: App crashes during processing
**Solution**:
- Reduce `config.width` to 3000 or less
- Use lower density (`.l` or `.xl`)
- Process videos in smaller batches

### Slow Processing
**Problem**: Taking too long
**Solution**:
- Set `useAccurateTimestamps = false`
- Use lower density
- Check CPU usage in Activity Monitor

### Poor Quality Output
**Problem**: Mosaic looks blurry or blocky
**Solution**:
- Increase `compressionQuality` to 0.6-0.8
- Increase `width`
- Use higher density setting (`.s` or `.xs`)

## Next Steps

1. ✅ You've completed the quick start!
2. 📖 Read the [full README](README.md) for advanced features
3. 🔧 Check out the [API documentation](API.md)
4. 💡 Try different configurations and find what works for you

## Need Help?

- 📚 Check the README for detailed documentation
- 🐛 Report issues on GitHub
- 💬 Ask questions in discussions

Happy mosaic generating! 🎨
