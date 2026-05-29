# ``MosaicKit``

High-performance video mosaic generation with platform-optimized image processing for macOS and iOS.

@Metadata {
    @TechnologyRoot
    @Available(macOS, introduced: "15.0")
    @Available(iOS, introduced: "15.0")
}

## Overview

MosaicKit is a powerful Swift package that generates beautiful video mosaics by extracting frames from videos and arranging them into configurable layouts. The library uses Metal GPU acceleration on all supported platforms (macOS, iOS, macCatalyst) for maximum performance.

### Key Features

- **Metal GPU Acceleration**: Single high-performance engine on every platform
- **Multiple Layout Algorithms**: Classic, custom, auto, dynamic, and iPhone-optimized layouts
- **Flexible Configuration**: Control density, aspect ratio, output format, and visual styling
- **Batch Processing**: Generate mosaics for multiple videos with intelligent concurrency management
- **Hardware Acceleration**: VideoToolbox for frame extraction, Metal for image processing
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

### Generator

- ``MetalMosaicGenerator``

### Preview Generation

- ``PreviewGeneratorCoordinator``
- ``PreviewVideoGenerator``
- ``PreviewConfiguration``

### Performance & Optimization

- <doc:PerformanceGuide>

### Error Handling

- ``MosaicError``
- ``LibraryError``
