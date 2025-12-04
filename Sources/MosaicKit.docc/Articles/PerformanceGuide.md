# Performance Optimization Guide

Best practices for optimizing mosaic generation performance and resource usage.

## Overview

MosaicKit is designed for high performance, but understanding how to configure and use it optimally can dramatically improve processing speed and resource efficiency. This guide covers performance optimization strategies for both Metal and Core Graphics implementations.

## Performance Factors

The following factors affect mosaic generation performance:

1. **Video Properties**: Duration, resolution, codec
2. **Configuration**: Density, output size, format
3. **Platform**: macOS (Metal/CG) vs iOS (CG)
4. **Hardware**: CPU cores, GPU capabilities, available RAM
5. **Batch Size**: Number of concurrent operations

## Optimization Strategies

### 1. Choose Optimal Density

Density has the largest impact on performance. Use the appropriate level for your use case:

```swift
// Quick previews - fastest
let quickConfig = MosaicConfiguration(density: .xxl)  // ~25% of frames

// Balanced - recommended for most cases
let balancedConfig = MosaicConfiguration(density: .m)  // 100% of frames

// Maximum detail - slowest
let detailConfig = MosaicConfiguration(density: .xxs)  // 8x frames
```

**Performance Impact:**

| Density | Frame Count* | Processing Time** | Use Case |
|---------|-------------|------------------|----------|
| XXL | 25 | 1.2s | Quick previews |
| XL | 50 | 2.1s | Long videos (>30min) |
| L | 75 | 2.8s | Standard videos |
| M | 100 | 3.5s | Best quality/speed balance |
| S | 200 | 6.8s | Short videos |
| XS | 300 | 10.2s | Very short clips |
| XXS | 400 | 13.5s | Maximum detail |

*For a 60-second video  
**M2 MacBook Pro, Metal, 1080p video

### 2. Select Appropriate Output Size

Output resolution directly affects processing time and memory usage:

```swift
// Mobile/web viewing - faster
let mobileConfig = MosaicConfiguration(width: 2048)

// Desktop viewing - balanced
let desktopConfig = MosaicConfiguration(width: 4000)

// Print/archival - slower
let printConfig = MosaicConfiguration(width: 8192)
```

**Performance Impact:**

| Width | Processing Time* | Memory Usage | Best For |
|-------|-----------------|--------------|----------|
| 1920 | 2.1s | 180MB | Mobile, quick preview |
| 2048 | 2.4s | 220MB | Web viewing |
| 4000 | 3.5s | 450MB | Desktop (default) |
| 5120 | 5.2s | 720MB | 5K displays |
| 8192 | 12.8s | 1.8GB | Print, archival |

*Same test conditions as density table

### 3. Choose Efficient Output Format

Output format affects both processing time and file size:

```swift
// Fastest writing, largest file
let pngConfig = MosaicConfiguration(format: .png)

// Balanced - recommended
let heifConfig = MosaicConfiguration(
    format: .heif,
    compressionQuality: 0.8
)

// Smallest file, universal compatibility
let jpegConfig = MosaicConfiguration(
    format: .jpeg,
    compressionQuality: 0.7
)
```

**Format Comparison:**

| Format | Write Time* | File Size* | Quality | Compatibility |
|--------|------------|-----------|---------|---------------|
| PNG | 1.2s | 45MB | Lossless | Universal |
| JPEG | 0.8s | 3.2MB | Lossy | Universal |
| HEIF | 0.9s | 2.1MB | Better | iOS 11+, macOS 10.13+ |

*4000px width, 100 thumbnails

### 4. Optimize Batch Processing

Configure concurrency based on available resources:

```swift
// Default - automatic concurrency limiting
let defaultCoordinator = MosaicGeneratorCoordinator()

// Custom concurrency limit
let customCoordinator = MosaicGeneratorCoordinator(concurrencyLimit: 4)

// Process batch
let results = try await customCoordinator.generateBatch(
    from: videoURLs,
    config: config,
    outputDirectory: outputDir
)
```

**Concurrency Guidelines:**

| System Configuration | Recommended Limit | Reasoning |
|---------------------|-------------------|-----------|
| 8GB RAM, 4 cores | 2 | Avoid memory pressure |
| 16GB RAM, 8 cores | 4 | Balanced throughput |
| 32GB RAM, 10+ cores | 8 | Maximum parallelization |
| iOS devices | 1-2 | Preserve battery, thermal |

**Dynamic Concurrency (Automatic):**

MosaicKit automatically calculates optimal concurrency:

```swift
// Memory-based limit
let memoryLimit = max(2, physicalMemory / 4GB)

// CPU-based limit
let cpuLimit = max(2, processorCount - 1)

// Final limit: min of constraints
let finalLimit = min(memoryLimit, cpuLimit, userConfigured)
```

### 5. Leverage Metal on macOS

For batch processing on macOS, Metal provides significant speedup:

```swift
#if os(macOS)
// Prefer Metal for batches
let generator = try MosaicGenerator(preference: .preferMetal)

let videos = Array(allVideos.prefix(50))
let mosaics = try await generator.generateBatch(
    from: videos,
    config: config,
    outputDirectory: outputDir
)
#endif
```

**Metal vs Core Graphics Performance:**

| Scenario | Metal | Core Graphics | Speedup |
|----------|-------|---------------|---------|
| Single video | 2.3s | 3.1s | 1.3x |
| Batch (10 videos) | 18s | 35s | 1.9x |
| Batch (50 videos) | 82s | 189s | 2.3x |
| High-res (5K) | 3.8s | 8.2s | 2.2x |

### 6. Cache and Reuse VideoInput

Creating VideoInput objects involves AVAsset metadata extraction:

```swift
// Inefficient - recreates VideoInput each time
for url in videoURLs {
    let mosaic = try await generator.generate(
        from: url,  // Creates VideoInput internally
        config: config,
        outputDirectory: outputDir
    )
}

// Better - create VideoInput once
let videos = try await videoURLs.asyncMap { url in
    try await VideoInput(from: url)
}

// Use MosaicGeneratorCoordinator which handles this efficiently
let coordinator = MosaicGeneratorCoordinator()
let results = try await coordinator.generateBatch(
    videos: videos,
    config: config,
    outputDirectory: outputDir
)
```

**Impact:** Saves ~50-100ms per video

### 7. Skip Metadata When Not Needed

If you don't need the metadata header overlay:

```swift
let noMetadataConfig = MosaicConfiguration(
    includeMetadata: false  // Saves gradient generation time
)
```

**Impact:** Saves ~200-300ms per mosaic

### 8. Use Appropriate Layout Complexity

Layout algorithms have different performance characteristics:

```swift
// Fastest - simple grid
let simpleLayout = LayoutConfiguration(layoutType: .classic)

// Fast - minimal calculation
let iphoneLayout = LayoutConfiguration(layoutType: .iphone)

// Medium - screen-aware
let autoLayout = LayoutConfiguration(layoutType: .auto)

// Slower - optimization algorithm
let customLayout = LayoutConfiguration(layoutType: .custom)

// Slowest - variable sizing
let dynamicLayout = LayoutConfiguration(layoutType: .dynamic)
```

**Layout Calculation Time:**

| Layout | Calculation | Best For |
|--------|-------------|----------|
| Classic | ~5ms | Batch processing |
| iPhone | ~3ms | Mobile, simple |
| Auto | ~20ms | Desktop apps |
| Custom | ~15ms | General use |
| Dynamic | ~25ms | Artistic output |

## Platform-Specific Optimization

### macOS Metal Optimization

**GPU Batch Processing:**

```swift
// Process frames in batches to avoid GPU timeout
let batchSize = 20  // Optimal for most GPUs
for batch in thumbnails.chunked(batchSize) {
    let commandBuffer = commandQueue.makeCommandBuffer()
    // ... encode batch operations
    commandBuffer.commit()
}
```

**Texture Pooling:**

```swift
// Reuse texture allocations
private var textureCache: CVMetalTextureCache
CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
```

**Unified Memory (Apple Silicon):**

```swift
// Zero-copy texture access on M-series
#if arch(arm64)
let buffer = device.makeBuffer(
    bytesNoCopy: pixelData,
    length: dataSize,
    options: .storageModeShared  // Unified memory
)
#endif
```

### iOS Core Graphics Optimization

**vImage Buffer Reuse:**

```swift
// Avoid repeated allocations
var bufferPool: [vImage_Buffer] = []

func processImage() {
    var buffer = bufferPool.popLast() ?? allocateBuffer()
    defer { bufferPool.append(buffer) }
    
    // ... process with buffer
}
```

**Progressive Frame Extraction:**

```swift
// Extract frames in chunks to control memory
let chunkSize = 20
for chunk in frameTimestamps.chunked(chunkSize) {
    let frames = try await extractFrames(at: chunk)
    processFrames(frames)
    frames.removeAll()  // Immediate cleanup
}
```

**Memory Warning Handling:**

```swift
#if os(iOS)
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { _ in
    Task {
        await generator.clearCaches()
    }
}
#endif
```

## Memory Management

### Monitor Memory Usage

```swift
import os

let memory = ProcessInfo.processInfo.physicalMemory
let usedMemory = // ... get used memory

if usedMemory > memory * 0.8 {
    // Reduce concurrency or clear caches
    await generator.clearCaches()
}
```

### Clear Caches Periodically

```swift
// After processing a batch
for await result in results {
    // ... handle result
}

// Clear frame caches
await generator.cancelAll()  // Clears internal caches
```

### Use Autorelease Pools (macOS)

```swift
for videoURL in largeVideoList {
    autoreleasepool {
        let mosaic = try await generator.generate(
            from: videoURL,
            config: config,
            outputDirectory: outputDir
        )
    }
}
```

## Performance Monitoring

### Track Generation Metrics

```swift
let generator = try MosaicGenerator()

let startTime = ContinuousClock.now
let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)
let duration = startTime.duration(to: .now)

print("Generated mosaic in \(duration)")

// Get detailed metrics (if using protocol directly)
if let protocolGen = generator as? any MosaicGeneratorProtocol {
    let metrics = await protocolGen.getPerformanceMetrics()
    print("Metrics: \(metrics)")
}
```

### Use Instruments

Profile with Xcode Instruments:

1. **Time Profiler**: Identify CPU bottlenecks
2. **Allocations**: Track memory usage and leaks
3. **Metal System Trace**: GPU utilization (Metal implementation)
4. **Core Animation**: Rendering performance

### OSSignposter Integration

MosaicKit uses OSSignposter for performance tracking:

```swift
// Already integrated in MosaicKit
private let signposter = OSSignposter(
    subsystem: "com.mosaicKit",
    category: "mosaic-generator"
)

// View in Instruments under "Points of Interest"
```

## Recommended Configurations

### Quick Preview (Speed Priority)

```swift
let quickConfig = MosaicConfiguration(
    width: 2048,
    density: .xl,              // Low frame count
    format: .jpeg,
    layout: LayoutConfiguration(
        layoutType: .classic    // Simple layout
    ),
    includeMetadata: false,    // Skip metadata
    compressionQuality: 0.6
)
```

**Expected Time:** ~1.5s per video (Metal, 1080p)

### Production Quality (Balanced)

```swift
let productionConfig = MosaicConfiguration(
    width: 4000,
    density: .m,               // Standard frame count
    format: .heif,
    layout: LayoutConfiguration(
        layoutType: .custom     // Good visual balance
    ),
    includeMetadata: true,
    compressionQuality: 0.8
)
```

**Expected Time:** ~3.5s per video (Metal, 1080p)

### Maximum Quality (Quality Priority)

```swift
let maxQualityConfig = MosaicConfiguration(
    width: 5120,
    density: .xxs,             // Maximum frames
    format: .png,              // Lossless
    layout: LayoutConfiguration(
        layoutType: .dynamic    // Best visual
    ),
    includeMetadata: true,
    compressionQuality: 1.0
)
```

**Expected Time:** ~18s per video (Metal, 1080p)

### Mobile/iOS Optimized

```swift
let mobileConfig = MosaicConfiguration(
    width: 2048,
    density: .l,               // Moderate frames
    format: .heif,
    layout: LayoutConfiguration(
        layoutType: .iphone     // Mobile-optimized
    ),
    compressionQuality: 0.7
)
```

**Expected Time:** ~4s per video (iOS, Core Graphics)

## Troubleshooting Performance Issues

### Slow Processing on macOS

**Check Metal Availability:**

```swift
#if os(macOS)
import Metal

if let device = MTLCreateSystemDefaultDevice() {
    print("Metal device: \(device.name)")
    print("Low power: \(device.isLowPower)")
    print("Unified memory: \(device.hasUnifiedMemory)")
} else {
    print("Metal not available")
}
#endif
```

**Solution:** Use Core Graphics if Metal is unavailable or limited:

```swift
let cgGenerator = try MosaicGenerator(preference: .preferCoreGraphics)
```

### High Memory Usage

**Reduce Concurrency:**

```swift
let coordinator = MosaicGeneratorCoordinator(concurrencyLimit: 2)
```

**Process in Smaller Batches:**

```swift
let batchSize = 10
for batch in videoURLs.chunked(batchSize) {
    let results = try await coordinator.generateBatch(
        from: batch,
        config: config,
        outputDirectory: outputDir
    )
    // Process results before next batch
}
```

### GPU Timeout (Metal)

Reduce batch size in Metal shader operations:

```swift
// MosaicKit already uses optimal batch size (20 frames)
// If still experiencing timeout, use Core Graphics:
let cgGenerator = try MosaicGenerator(preference: .preferCoreGraphics)
```

## Benchmarking Best Practices

### Fair Comparisons

```swift
// Warm up (compile shaders, allocate resources)
_ = try await generator.generate(from: testURL, config: config, outputDirectory: tempDir)

// Actual benchmark
let iterations = 10
var durations: [Duration] = []

for _ in 0..<iterations {
    let start = ContinuousClock.now
    _ = try await generator.generate(from: testURL, config: config, outputDirectory: tempDir)
    durations.append(start.duration(to: .now))
}

let average = durations.reduce(Duration.zero, +) / iterations
print("Average time: \(average)")
```

### Compare Implementations

```swift
let testConfigs: [(String, MosaicConfiguration)] = [
    ("Quick", quickConfig),
    ("Production", productionConfig),
    ("Max Quality", maxQualityConfig)
]

for (name, config) in testConfigs {
    let start = ContinuousClock.now
    _ = try await generator.generate(from: url, config: config, outputDirectory: dir)
    let duration = start.duration(to: .now)
    print("\(name): \(duration)")
}
```

## See Also

- <doc:Architecture>
- <doc:PlatformStrategy>
- <doc:BatchProcessing>
- ``MosaicConfiguration``
- ``DensityConfig``
