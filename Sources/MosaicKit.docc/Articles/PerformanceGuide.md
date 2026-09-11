# Performance Optimization Guide

Best practices for optimizing mosaic generation performance and resource usage.

## Overview

MosaicKit is designed for high performance, but understanding how to configure and use it optimally can dramatically improve processing speed and resource efficiency. This guide covers performance optimization strategies for the single Metal GPU engine used on every platform (macOS, iOS, macCatalyst) — see <doc:PlatformStrategy> for why there is no Core Graphics fallback.

## Performance Factors

The following factors affect mosaic generation performance:

1. **Video Properties**: Duration, resolution, codec
2. **Configuration**: Density, output size, format
3. **Hardware**: GPU capabilities, CPU cores, available RAM
4. **Batch Size**: Number of concurrent operations

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
// Default - automatic concurrency limiting (concurrencyLimit: 0)
let defaultCoordinator = try createDefaultMosaicCoordinator()

// Custom concurrency limit
let customCoordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 4)

// Process batch
let results = try await customCoordinator.generateMosaicsforbatch(
    videos: videos,
    config: config
) { progress in
    print("Progress: \(progress)")
}
```

**Concurrency Guidelines:**

| System Configuration | Recommended Limit | Reasoning |
|---------------------|-------------------|-----------|
| 8GB RAM, 4 cores | 2 | Avoid memory pressure |
| 16GB RAM, 8 cores | 4 | Balanced throughput |
| 32GB RAM, 10+ cores | 8 | Maximum parallelization |
| iOS devices | 1-2 | Preserve battery, thermal |

**Dynamic Concurrency (Automatic):**

When `concurrencyLimit` is `0` (the default from `createDefaultMosaicCoordinator()`),
`MosaicGeneratorCoordinator` recalculates the effective limit for each batch:

```swift
// CPU-based limit: half the active processor cores, minimum 2
let cpuBasedLimit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

// Memory-based limit: scales down with output width and density
let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
let memoryPerTask = Double(config.width) * config.density.factor / 2000.0
let memoryBasedLimit = max(2, Int(memoryGB / memoryPerTask))

// Final limit: the more conservative of the two
let effectiveLimit = min(memoryBasedLimit, cpuBasedLimit)
```

Passing a non-zero `concurrencyLimit` (or calling `setConcurrencyLimit(_:)`) overrides this and is
re-read live at the start of each batch iteration, so it can be adjusted mid-run.

### 5. Batch Through the Coordinator, Not a Loop of Single Calls

`MosaicGeneratorCoordinator` reuses one `MetalMosaicGenerator` (and its GPU device/command queue)
across every video in a batch, instead of paying Metal device/library setup cost per call:

```swift
let coordinator = try createDefaultMosaicCoordinator()

let results = try await coordinator.generateMosaicsforbatch(
    videos: Array(allVideos.prefix(50)),
    config: config
) { progress in
    print("Progress: \(progress)")
}
```

### 6. Cache and Reuse VideoInput

Creating `VideoInput` objects involves `AVAsset` metadata extraction:

```swift
// Inefficient - constructs a fresh VideoInput on every generate() call
for url in videoURLs {
    let video = try await VideoInput(from: url)
    let mosaic = try await generator.generate(for: video, config: config)
}

// Better - build every VideoInput once, then hand the coordinator the whole batch
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
```

`scanVideos(in:recursive:)` builds a `[VideoInput]` directly from a directory if that fits your
workflow better than constructing each `VideoInput` by hand.

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

## GPU-Level Optimization

These are the techniques `MetalImageProcessor` itself already applies internally — useful context
if you're profiling generation, though there's nothing here for callers to configure:

**GPU Batch Processing:** frames are encoded and committed in batches of 20 per command buffer
(`MetalImageProcessor.generateMosaic`), which keeps individual command buffers small enough to avoid
GPU timeouts while still pipelining well.

**Texture Pooling:** `MetalImageProcessor` reuses a `CVMetalTextureCache` for `CVPixelBuffer`-backed
textures rather than allocating a new `MTLTexture` per frame.

**Unified Memory (Apple Silicon / iOS):** on unified-memory devices, textures are shared between CPU
and GPU with no explicit copy step, which is one reason the single Metal path performs well across
both macOS and iOS.

### Memory Warning Handling (iOS)

There's no dedicated cache-clearing entry point beyond canceling in-flight work. On a memory
warning, canceling active generations also drops their frame caches:

```swift
#if os(iOS)
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { _ in
    Task {
        await generator.cancelAll()  // Cancels in-flight tasks and clears frameCache
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
    // Reduce concurrency, or cancel in-flight work to drop cached frames
    await generator.cancelAll()
}
```

### Clear Caches Periodically

`MetalMosaicGenerator` caches extracted frames per video (`frameCache: [UUID: [CMTime: CGImage]]`)
until that video's generation completes or is cancelled. There's no standalone "clear caches"
call — `cancelAll()` cancels every in-flight task and clears the cache as a side effect:

```swift
// After processing a batch
for result in results {
    // ... handle result
}

await generator.cancelAll()
```

## Performance Monitoring

### Track Generation Metrics

```swift
let generator = try MetalMosaicGenerator()
let video = try await VideoInput(from: videoURL)

let startTime = ContinuousClock.now
let mosaicURL = try await generator.generate(for: video, config: config)
let duration = startTime.duration(to: .now)

print("Generated mosaic in \(duration)")

// getPerformanceMetrics() is part of MosaicGeneratorProtocol
let metrics = await generator.getPerformanceMetrics()
print("Metrics: \(metrics)")
```

### Use Instruments

Profile with Xcode Instruments:

1. **Time Profiler**: Identify CPU bottlenecks
2. **Allocations**: Track memory usage and leaks
3. **Metal System Trace**: GPU utilization

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

**Expected Time:** ~4s per video (Metal, 1080p)

## Troubleshooting Performance Issues

### Confirm Metal Is Available

Every platform this package targets (macOS 26+, iOS 26+, macCatalyst 26+) is expected to have a
usable Metal device, but if `MetalMosaicGenerator()`'s initializer throws
`MetalProcessorError.deviceNotAvailable`, inspect the device directly:

```swift
import Metal

if let device = MTLCreateSystemDefaultDevice() {
    print("Metal device: \(device.name)")
    print("Low power: \(device.isLowPower)")
    print("Unified memory: \(device.hasUnifiedMemory)")
} else {
    print("Metal not available")
}
```

There is no Core Graphics fallback to switch to — this indicates an unusual sandboxed or
virtualized environment rather than something to configure around.

### High Memory Usage

**Reduce Concurrency:**

```swift
let coordinator = try createDefaultMosaicCoordinator(concurrencyLimit: 2)
```

**Process in Smaller Batches:**

```swift
let batchSize = 10
for start in stride(from: 0, to: videos.count, by: batchSize) {
    let batch = Array(videos[start..<min(start + batchSize, videos.count)])
    let results = try await coordinator.generateMosaicsforbatch(
        videos: batch,
        config: config
    ) { progress in print(progress) }
    // Process results before next batch
}
```

### GPU Timeout (Metal)

`MetalImageProcessor` already batches frame composition at 20 frames per command buffer
internally — this isn't something callers configure. If you still see command buffer failures,
check for `MetalProcessorError.commandBufferExecutionFailed(context:underlying:)` in the thrown
error's `underlying` string, which carries the GPU's actual failure reason.

## Benchmarking Best Practices

### Fair Comparisons

```swift
let generator = try MetalMosaicGenerator()
let testVideo = try await VideoInput(from: testURL)

// Warm up (compile shaders, allocate resources)
_ = try await generator.generate(for: testVideo, config: config)

// Actual benchmark
let iterations = 10
var durations: [Duration] = []

for _ in 0..<iterations {
    let start = ContinuousClock.now
    _ = try await generator.generate(for: testVideo, config: config)
    durations.append(start.duration(to: .now))
}

let average = durations.reduce(Duration.zero, +) / iterations
print("Average time: \(average)")
```

### Compare Configurations

```swift
let testConfigs: [(String, MosaicConfiguration)] = [
    ("Quick", quickConfig),
    ("Production", productionConfig),
    ("Max Quality", maxQualityConfig)
]

for (name, config) in testConfigs {
    let start = ContinuousClock.now
    _ = try await generator.generate(for: testVideo, config: config)
    let duration = start.duration(to: .now)
    print("\(name): \(duration)")
}
```

## See Also

- <doc:Architecture>
- <doc:PlatformStrategy>
- ``MosaicConfiguration``
- ``DensityConfig``
- ``MosaicGeneratorCoordinator``
