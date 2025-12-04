# ``MosaicKit``

High-performance video mosaic generation with platform-optimized image processing for macOS and iOS.

@Metadata {
    @TechnologyRoot
    @Available(macOS, introduced: "26.0")
    @Available(iOS, introduced: "26.0")
}

## Overview

MosaicKit is a powerful Swift package that generates beautiful video mosaics by extracting frames from videos and arranging them into configurable layouts. The library leverages platform-specific optimizations to deliver maximum performance:

- **macOS**: Metal GPU acceleration for blazing-fast processing
- **iOS**: Core Graphics with vImage/Accelerate framework optimization

### Key Features

- **Dual Processing Engines**: Automatic selection of optimal processing engine based on platform
- **Multiple Layout Algorithms**: Classic, custom, auto, dynamic, and iPhone-optimized layouts
- **Flexible Configuration**: Control density, aspect ratio, output format, and visual styling
- **Batch Processing**: Generate mosaics for multiple videos with intelligent concurrency management
- **Hardware Acceleration**: VideoToolbox for frame extraction, Metal/vImage for image processing
- **Preview Generation**: Create condensed video previews from full-length videos

## Topics

### Getting Started

- <doc:GettingStarted>
- <doc:QuickStart>

### Architecture & Design

- <doc:Architecture>
- <doc:PlatformStrategy>
- <doc:LayoutAlgorithms>

### Core Components

- ``MosaicGenerator``
- ``MosaicGeneratorProtocol``
- ``MosaicGeneratorFactory``
- ``VideoInput``

### Configuration

- ``MosaicConfiguration``
- ``DensityConfig``
- ``LayoutConfiguration``
- ``OutputFormat``

### Layout System

- ``LayoutProcessor``
- ``MosaicLayout``
- ``LayoutType``
- ``AspectRatio``

### Platform-Specific Generators

- ``MetalMosaicGenerator``
- ``CoreGraphicsMosaicGenerator``

### Preview Generation

- ``PreviewGeneratorCoordinator``
- ``PreviewVideoGenerator``
- ``PreviewConfiguration``

### Performance & Optimization

- <doc:PerformanceGuide>
- <doc:BatchProcessing>

### Error Handling

- ``MosaicError``
- ``LibraryError``

### Advanced Topics

- <doc:CustomLayouts>
- <doc:MigrationGuide>
