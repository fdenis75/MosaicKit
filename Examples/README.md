# MosaicKit Examples

This directory contains working examples demonstrating how to use MosaicKit.

## Running the Examples

### Simple Example (Start Here!)

The easiest way to use MosaicKit:

```bash
swift run SimpleExample
```

Demonstrates:
- Simplest possible API
- One-step generation
- Minimal code required

### Basic Example

Simple single-video mosaic generation:

```bash
swift run BasicExample
```

Demonstrates:
- Loading a video
- Basic configuration
- Generating a mosaic
- Displaying results and metrics

### Batch Example

Process multiple videos concurrently:

```bash
swift run BatchExample
```

Demonstrates:
- Batch processing
- Progress tracking for multiple videos
- Concurrency management
- Result handling

### Advanced Example

Multiple configurations and layouts:

```bash
swift run AdvancedExample
```

Demonstrates:
- Quick preview generation
- High-quality output
- Square format for social media
- iPhone-optimized layout
- Custom layouts with borders and shadows

## Modifying the Examples

Before running, update the file paths in each example:

```swift
// Change these paths to your actual files
let videoURL = URL(fileURLWithPath: "/path/to/your/video.mp4")
let outputDir = URL(fileURLWithPath: "/path/to/output")
```

## Example Structure

### SimpleExample.swift
The absolute simplest way to use MosaicKit. Perfect for getting started.

**What it shows:**
- High-level MosaicGenerator API
- One-step generation
- Minimal configuration
- Quick results

**Complexity:** ⭐ (Easiest)

### BasicExample.swift
Entry-level example showing the simplest way to generate a mosaic. Perfect for getting started.

**What it shows:**
- Video loading with metadata extraction
- Default configuration
- Simple generation
- Performance metrics

**Complexity:** ⭐

### BatchExample.swift
Intermediate example for processing multiple videos efficiently.

**What it shows:**
- Loading multiple videos
- Batch processing with coordinator
- Progress tracking
- Error handling per video
- Results aggregation

**Complexity:** ⭐⭐⭐

### AdvancedExample.swift
Advanced techniques and configurations.

**What it shows:**
- Multiple configuration presets
- Different output formats
- Custom layouts
- Aspect ratio variations
- Progress tracking implementation
- Comprehensive error handling

**Complexity:** ⭐⭐⭐⭐⭐

## Common Modifications

### Change Output Size

```swift
config.width = 8000  // Larger mosaic
config.width = 2000  // Smaller mosaic
```

### Adjust Frame Density

```swift
config.density = .xl   // Fewer frames (faster)
config.density = .xxs  // More frames (detailed)
```

### Change Output Format

```swift
config.format = .heif  // Best compression
config.format = .jpeg  // More compatible
config.format = .png   // Lossless
```

### Modify Aspect Ratio

```swift
config.layout.aspectRatio = .widescreen  // 16:9
config.layout.aspectRatio = .square      // 1:1
config.layout.aspectRatio = .vertical    // 9:16
```

## Tips for Testing

1. **Start Small**: Begin with low width (2000) and low density (.xl) for quick tests
2. **Check Output**: Verify the output directory exists before running
3. **Monitor Performance**: Watch Activity Monitor for memory usage
4. **Test Incrementally**: Try one configuration at a time

## Performance Benchmarks

Typical processing times on M1 Max (example video: 2 minutes, 1080p):

| Configuration | Width | Density | Time | Output Size |
|--------------|-------|---------|------|-------------|
| Quick Preview | 2000 | .xl | ~5s | 2-3 MB |
| Standard | 5000 | .m | ~15s | 8-10 MB |
| High Quality | 8000 | .xs | ~45s | 15-20 MB |

Your mileage may vary based on:
- Video resolution
- Video length
- System specifications
- Disk speed
- Configuration settings

## Troubleshooting

### "No such file or directory"
Update the video path to point to an actual video file:
```swift
let videoURL = URL(fileURLWithPath: "/Users/you/Movies/video.mp4")
```

### "Permission denied"
Ensure the output directory exists and is writable:
```bash
mkdir -p /path/to/output
```

### Out of Memory
Reduce configuration settings:
```swift
config.width = 3000  // Lower width
config.density = .l  // Lower density
```

### Slow Processing
Disable accurate timestamps for faster processing:
```swift
config.useAccurateTimestamps = false
```

## Next Steps

After running these examples:

1. 📖 Read the [full README](../README.md) for detailed documentation
2. 🔍 Check the [API Reference](../API.md) for complete API details
3. 🎨 Experiment with different configurations
4. 🚀 Integrate MosaicKit into your own projects

## Need Help?

- Check the main README for troubleshooting
- Open an issue on GitHub
- Review the API documentation

Happy mosaic generating! 🎬
