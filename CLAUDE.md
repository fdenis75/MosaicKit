# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MosaicKit is a Swift package for generating video mosaics with Metal-accelerated image processing. It extracts frames from videos and arranges them into configurable mosaic layouts with optional metadata headers.

Key features:
- Metal-accelerated mosaic generation for high performance
- Multiple layout algorithms (classic, custom, auto, dynamic, iPhone-optimized)
- Configurable density levels for frame extraction
- Multiple output formats (JPEG, PNG, HEIF)
- Batch processing with intelligent concurrency management
- VideoToolbox hardware-accelerated frame extraction

## Architecture

### Core Components

**Processing Pipeline:**
1. `MosaicGenerator` - Main public API entry point
2. `MosaicGeneratorCoordinator` - Manages batch operations with concurrency control
3. `MetalMosaicGenerator` - Actor-based Metal-accelerated generator
4. `LayoutProcessor` - Calculates optimal thumbnail layouts
5. `ThumbnailProcessor` - Extracts video frames using VideoToolbox
6. `MetalImageProcessor` - GPU-accelerated mosaic composition

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
`MosaicGeneratorFactory` assesses hardware capabilities and creates the appropriate generator.

## Development Commands

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

### Metal Processing

The package requires Metal support. Metal availability is checked at initialization:
```swift
guard MTLCreateSystemDefaultDevice() != nil else {
    throw MosaicError.metalNotSupported
}
```

### Concurrency Model

- `MetalMosaicGenerator` is an actor for thread-safe Metal operations
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

- Minimum: macOS 14, iOS 17
- Some features require: macOS 15, iOS 18 (marked with `@available`)
- Cross-platform support via conditional imports:
  - `#if canImport(AppKit)` for macOS
  - `#if canImport(UIKit)` for iOS

## Dependencies

- `swift-log` (1.5.0+): Structured logging
- `DominantColors` (1.2.0+): Color analysis for metadata
- Native: AVFoundation, Metal, VideoToolbox, CoreImage

## Common Patterns

### Error Handling

The package defines domain-specific errors:
- `MosaicError`: Mosaic generation errors
- `LibraryError`: Library operation errors

### Performance Optimization

- Frame extraction uses VideoToolbox hardware acceleration
- Mosaic composition leverages Metal shaders (Resources/Shaders/)
- Performance metrics tracked via `getPerformanceMetrics()`
- OSSignposter used for profiling critical paths

### Actor Isolation

When working with `MetalMosaicGenerator` or `MosaicGeneratorCoordinator`, remember they are actors. Use `await` for all method calls and wrap in `Task` if calling from non-async contexts.
