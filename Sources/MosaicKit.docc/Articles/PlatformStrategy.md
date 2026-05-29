# Platform-Specific Processing Strategy

Understanding how MosaicKit uses Metal GPU acceleration across all supported platforms.

## Overview

MosaicKit uses Metal GPU acceleration on all supported platforms (macOS, iOS, macCatalyst). This provides
consistent high-performance behaviour and a single code path to maintain.

## Metal GPU Acceleration

Metal is available on all Apple platforms since iOS 8 and macOS 10.11. MosaicKit requires iOS 26+
and macOS 26+, so Metal support is guaranteed on every target device.

### Why Metal Everywhere?

1. **Parallel Processing**: GPUs process thousands of pixels simultaneously
2. **Unified Memory (Apple Silicon / all iOS)**: Zero-copy texture access — no CPU↔GPU copies
3. **Hardware Filters**: Built-in support for high-quality scaling and compositing
4. **Single Implementation**: One code path reduces bugs and maintenance burden

### Metal Architecture

```swift
public actor MetalMosaicGenerator: MosaicGeneratorProtocol {
    private let metalProcessor: MetalImageProcessor

    // Core Metal resources (shared across platforms)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
}
```

**Key Components:**

**Metal Shaders** (`Sources/Shaders/`):
- Kernel functions for image compositing
- GPU-parallel pixel processing
- Alpha blending operations

**Texture Management:**
```swift
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm,
    width: width,
    height: height,
    mipmapped: false
)
textureDescriptor.usage = [.shaderRead, .shaderWrite]
// .private for GPU-only intermediates, default (.shared) for final read-back
let texture = device.makeTexture(descriptor: textureDescriptor)
```

**Command Buffer Batching:**
```swift
// 20 frames per command buffer to avoid GPU timeout
for batch in thumbnails.chunked(20) {
    let commandBuffer = commandQueue.makeCommandBuffer()
    // Encode batch operations
    commandBuffer.commit()
    await commandBuffer.completed()
}
```

### Performance Profile

**Strengths:**
- Large batch processing (10+ videos): 3-5× faster than CPU rendering
- High-resolution outputs (4K, 5K, 8K): GPU scaling is very efficient
- Complex visual effects: Hardware-accelerated blur, gradients, shadows

**Note on unified memory (iOS / Apple Silicon):**
All iOS devices use a unified memory architecture. Metal textures declared as `.private` stay
GPU-resident, while intermediate-to-final read-back uses the default `.shared` storage mode —
no explicit synchronisation is needed.

**Optimal Scenarios:**
```swift
// Metal is the default on every platform
let generator = try MosaicGenerator()

let config = MosaicConfiguration(
    width: 5120,
    density: .xxs
)
let mosaics = try await generator.generateBatch(
    from: videoURLs,
    config: config,
    outputDirectory: outputDir
)
```

## Usage

### Automatic Selection (Recommended)

```swift
// Metal is always selected automatically
let generator = try MosaicGenerator()
```

### Explicit Metal

```swift
let generator = try MosaicGenerator(preference: .preferMetal)
```

## Metal Debugging

Enable Metal API validation in Xcode:
```
Product → Scheme → Edit Scheme → Run → Diagnostics → Metal API Validation
```

Monitor GPU utilisation on macOS:
```bash
sudo powermetrics --samplers gpu_power -i 1000
```

## See Also

- <doc:Architecture>
- <doc:PerformanceGuide>
- ``MosaicGeneratorFactory``
- ``MetalMosaicGenerator``
