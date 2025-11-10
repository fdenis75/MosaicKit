# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MosaicKit is a Swift package for generating video mosaics with platform-optimized image processing. It extracts frames from videos and arranges them into configurable mosaic layouts with optional metadata headers.

Key features:
- **Platform-specific acceleration:**
  - **macOS**: Metal GPU acceleration for maximum performance
  - **iOS**: Core Graphics with vImage/Accelerate optimization
- Multiple layout algorithms (classic, custom, auto, dynamic, iPhone-optimized)
- Configurable density levels for frame extraction
- Multiple output formats (JPEG, PNG, HEIF)
- Batch processing with intelligent concurrency management
- VideoToolbox hardware-accelerated frame extraction

## Architecture

### Core Components

**Processing Pipeline:**
1. `MosaicGenerator` - Main public API entry point (platform-aware)
2. `MosaicGeneratorCoordinator` - Manages batch operations with concurrency control
3. **Platform-Specific Generators:**
   - `MetalMosaicGenerator` (macOS) - Actor-based Metal-accelerated generator
   - `CoreGraphicsMosaicGenerator` (iOS) - Actor-based Core Graphics generator
4. `LayoutProcessor` - Calculates optimal thumbnail layouts
5. `ThumbnailProcessor` - Extracts video frames using VideoToolbox
6. **Platform-Specific Image Processors:**
   - `MetalImageProcessor` (macOS) - GPU-accelerated mosaic composition
   - `CoreGraphicsImageProcessor` (iOS) - vImage/Accelerate-accelerated composition

**Layout System:**
The layout system provides multiple algorithms optimized for different use cases:
- **Custom Layout**: Three-zone layout (small/large/small) with centered large thumbnails
- **Classic Layout**: Grid-based layout with optimal spacing
- **Auto Layout**: Screen-aware layout based on display size
- **Dynamic Layout**: Center-emphasized layout with variable thumbnail sizes
- **iPhone Layout**: Fixed-width vertical scrolling optimized for mobile

**Models:**
- `VideoInput` - Simplified video metadata model (no SwiftData dependency)
- `MosaicConfiguration` - Complete mosaic generation settings
- `MosaicLayout` - Layout dimensions and thumbnail positions
- `DensityConfig` - Frame extraction density (XXL to XXS)
- `LayoutConfiguration` - Visual settings and aspect ratios

**Factory Pattern:**
`MosaicGeneratorFactory` uses platform detection and user preference to create generators:
- **Default behavior (`.auto`):**
  - **macOS**: Returns `MetalMosaicGenerator`
  - **iOS**: Returns `CoreGraphicsMosaicGenerator`
- **Manual selection:**
  - `.preferMetal`: Metal on macOS, falls back to Core Graphics on iOS
  - `.preferCoreGraphics`: Core Graphics on both macOS and iOS

**Why choose Core Graphics on macOS?**
- Testing iOS behavior on macOS
- Systems without adequate GPU resources
- Environments where Metal is unavailable
- Comparing performance between implementations

## Development Commands

### Using the Package

```swift
// Default: Auto-selects Metal on macOS, Core Graphics on iOS
let generator = try MosaicGenerator()

// Force Core Graphics on macOS (for testing iOS behavior)
let cgGenerator = try MosaicGenerator(preference: .preferCoreGraphics)

// Prefer Metal (falls back to CG on iOS)
let metalGenerator = try MosaicGenerator(preference: .preferMetal)

// Generate mosaic
let mosaicURL = try await generator.generate(
    from: videoURL,
    config: config,
    outputDirectory: outputDir
)
```

### Building

```bash
# Build the package
swift build

# Build with optimizations
swift build -c release

# Build specific target
swift build --target MosaicKit
```

### Testing

```bash
# Run all tests
swift test

# Run tests with parallel execution
swift test --parallel

# Run specific test
swift test --filter MosaicKitTests
```

### Using in Xcode

```bash
# Generate Xcode project (if needed)
swift package generate-xcodeproj

# Or open Package.swift directly in Xcode
open Package.swift
```

## Key Technical Details

### Platform-Specific Processing

#### macOS: Metal Processing

Metal GPU acceleration is used on macOS. Availability is checked at initialization:
```swift
#if os(macOS)
guard MTLCreateSystemDefaultDevice() != nil else {
    throw MosaicError.metalNotSupported
}
#endif
```

Metal operations include:
- High-quality texture scaling with bilinear/trilinear filtering
- Alpha-blended compositing using GPU shaders
- Batch processing with 20 frames per command buffer to avoid GPU timeout

#### iOS: Core Graphics + vImage Processing

Core Graphics with Accelerate framework optimization is used on iOS:
```swift
#if os(iOS)
// Uses vImage for high-performance operations
import Accelerate

// High-quality image scaling
vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, kvImageHighQualityResampling)

// Alpha-blended compositing
context.draw(image, in: rect) // Hardware-accelerated on iOS
```

Core Graphics operations include:
- High-quality Lanczos interpolation for scaling via vImage
- Hardware-accelerated alpha blending via CGContext
- Gradient generation with Core Image blur effects
- Efficient memory management with buffer reuse

### Concurrency Model

- `MetalMosaicGenerator` (macOS) is an actor for thread-safe Metal operations
- `CoreGraphicsMosaicGenerator` (iOS) is an actor for thread-safe Core Graphics operations
- `MosaicGeneratorCoordinator` uses `withThrowingTaskGroup` for batch processing
- Dynamic concurrency limits based on system resources:
  - Memory-based: max(2, physicalMemory/4GB)
  - CPU-based: max(2, processorCount - 1)
  - Final limit: min(memory, cpu, configured limit)

### Layout Calculation

The `LayoutProcessor.calculateCustomLayout` uses an optimization algorithm:
1. Divides mosaic into 3 horizontal zones
2. Tests multiple small row configurations
3. Calculates size ratios based on target aspect ratio
4. Finds best layout minimizing thumbnail count difference
5. If no valid layout found, recursively tries with 80% of thumbnail count

### Frame Extraction Strategy

Frames are extracted with biased distribution:
- First third: 20% of frames
- Middle third: 60% of frames (captures most action)
- Last third: 20% of frames
- Skips first 5% and last 5% to avoid fade in/out

### Platform Compatibility

- **Minimum versions:**
  - macOS 15.0+ (Metal generator)
  - iOS 17.0+ (Core Graphics generator)
- **Platform-specific code patterns:**
  - `#if os(macOS)` for macOS-only code
  - `#if os(iOS)` for iOS-only code
  - `#if canImport(AppKit)` for AppKit features
  - `#if canImport(UIKit)` for UIKit features

## Dependencies

- `swift-log` (1.5.0+): Structured logging
- `DominantColors` (1.2.0+): Color analysis for gradient backgrounds
- **Native frameworks:**
  - AVFoundation (frame extraction)
  - VideoToolbox (hardware-accelerated decoding)
  - CoreImage (blur effects)
  - **macOS only:** Metal, MetalKit (GPU acceleration)
  - **iOS only:** Accelerate (vImage operations)

## Common Patterns

### Error Handling

The package defines domain-specific errors:
- `MosaicError`: Mosaic generation errors
- `LibraryError`: Library operation errors

### Performance Optimization

- Frame extraction uses VideoToolbox hardware acceleration (both platforms)
- **Platform-specific optimizations:**
  - **macOS:** Metal GPU shaders (Resources/Shaders/) for parallel processing
  - **iOS:** vImage/Accelerate for optimized CPU-based operations
- Performance metrics tracked via `getPerformanceMetrics()` on both generators
- OSSignposter used for profiling critical paths
- Batch processing with 20 frames per batch to maintain responsiveness

### Actor Isolation

When working with platform-specific generators or coordinator, remember they are actors:
- `MetalMosaicGenerator` (macOS)
- `CoreGraphicsMosaicGenerator` (iOS)
- `MosaicGeneratorCoordinator` (both)

Use `await` for all method calls and wrap in `Task` if calling from non-async contexts.

### Working with Platform-Specific Code

When adding new features:
1. For iOS-only code targeting Core Graphics, add to `CoreGraphicsImageProcessor` or `CoreGraphicsMosaicGenerator`
2. For macOS-only code targeting Metal, add to `MetalImageProcessor` or `MetalMosaicGenerator`
3. For shared code, use `#if os(macOS)` / `#if os(iOS)` conditionals
4. The factory (`MosaicGeneratorFactory`) handles platform detection automatically

### Protocol Conformance

Both generators implement `MosaicGeneratorProtocol`:
```swift
public protocol MosaicGeneratorProtocol: Actor {
    func generate(for video: VideoInput, config: MosaicConfiguration, forIphone: Bool) async throws -> URL
    func generateallcombinations(for video: VideoInput, config: MosaicConfiguration) async throws -> [URL]
    func cancel(for video: VideoInput)
    func cancelAll()
    func setProgressHandler(for video: VideoInput, handler: @escaping @Sendable (MosaicGenerationProgress) -> Void)
    func getPerformanceMetrics() -> [String: Any]
}
```

This protocol enables:
- Uniform interface for both implementations
- Easy switching between Metal and Core Graphics
- Testing one implementation against the other
- Type-safe factory pattern

### Testing Both Implementations on macOS

You can compare Metal vs Core Graphics performance on macOS:
```swift
// Test Metal
let metalGen = try MosaicGenerator(preference: .preferMetal)
let metalURL = try await metalGen.generate(from: videoURL, config: config, outputDirectory: dir)
let metalMetrics = await metalGen.getPerformanceMetrics()

// Test Core Graphics
let cgGen = try MosaicGenerator(preference: .preferCoreGraphics)
let cgURL = try await cgGen.generate(from: videoURL, config: config, outputDirectory: dir)
let cgMetrics = await cgGen.getPerformanceMetrics()

// Compare results
print("Metal time: \(metalMetrics["lastGenerationTime"])")
print("CoreGraphics time: \(cgMetrics["lastGenerationTime"])")
```
