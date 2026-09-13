# ``MosaicKit``

High-performance video mosaic generation with platform-optimized image processing for macOS and iOS.

@Metadata {
    @TechnologyRoot
    @Available(macOS, introduced: "26.0")
    @Available(iOS, introduced: "26.0")
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
- <doc:PreviewExporting>
- <doc:BackgroundProcessing>

### Architecture & Design

- <doc:PlatformStrategy>
- <doc:Architecture>
- <doc:LayoutAlgorithms>
- <doc:PerformanceGuide>

### Core Components

- ``MosaicGeneratorProtocol``
- ``MetalMosaicGenerator``
- ``MosaicGeneratorCoordinator``
- ``VideoInput``
- ``VideoSource``
- ``VideoMetadataExtractor``
- ``GenerationJobController``
- ``GenerationJobID``
- ``GenerationJobSnapshot``

### Configuration

- ``MosaicConfiguration``
- ``DensityConfig``
- ``LayoutConfiguration``
- ``OutputFormat``
- ``AnimatedFormat``
- ``GifCreationMode``
- ``GifSize``

### Layout System

- ``LayoutProcessor``
- ``MosaicLayout``
- ``LayoutType``
- ``AspectRatio``

### Animated Export

- ``AnimatedGifGenerator``

WebP output (`OutputFormat.webp` / `AnimatedFormat.webp`) requires linking the separate
`MosaicKitWebP` product and calling `MosaicKitWebP.register()` at startup — see
<doc:GettingStarted>.

### Preview Generation

- ``PreviewGeneratorCoordinator``
- ``PreviewVideoGenerator``
- ``PreviewConfiguration``
- ``PreviewExportMode``
- ``FFmpegEncodingOptions``
- ``FFmpegEncoder``
- ``PreviewGenerationProgress``
- ``PreviewExportDescription``

### Performance & Optimization

- <doc:PerformanceGuide>

### Reliability & Lifecycle

`MetalMosaicGenerator` and both coordinators observe Swift task cancellation at frame extraction,
GPU processing, and export boundaries. Outputs are written to a staging URL and atomically moved
into place only after validation, so cancellation or a failed retry cannot leave a partial file.
Use ``GenerationJobController`` when work needs stable IDs and explicit pause/retry controls.

### Error Handling

- ``MosaicError``
- ``LibraryError``
- ``VideoError``
- ``PreviewError``
- ``MetalProcessorError``
