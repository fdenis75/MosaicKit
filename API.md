# MosaicKit API Reference

Complete API documentation for MosaicKit.

## Table of Contents

- [Core Classes](#core-classes)
- [Models](#models)
- [Configuration](#configuration)
- [Errors](#errors)
- [Protocols](#protocols)

---

## Core Classes

### MosaicGenerator

Main entry point for simple mosaic generation.

```swift
public final class MosaicGenerator
```

#### Initializer

```swift
public init() throws
```

**Throws**: `MosaicError.metalNotSupported` if Metal is not available.

#### Methods

##### generate(from:config:outputDirectory:)

Generate a mosaic from a single video file.

```swift
public func generate(
    from videoURL: URL,
    config: MosaicConfiguration,
    outputDirectory: URL
) async throws -> URL
```

**Parameters**:
- `videoURL`: URL to the video file
- `config`: Mosaic generation configuration
- `outputDirectory`: Directory where the mosaic will be saved

**Returns**: URL to the generated mosaic file

**Throws**: `MosaicError` on failure

**Status**: ✅ Fully implemented

##### generateBatch(from:config:outputDirectory:progress:)

Generate mosaics from multiple video files.

```swift
public func generateBatch(
    from videoURLs: [URL],
    config: MosaicConfiguration,
    outputDirectory: URL,
    progress: ((Int, Int) -> Void)? = nil
) async throws -> [URL]
```

**Parameters**:
- `videoURLs`: Array of video file URLs
- `config`: Mosaic generation configuration
- `outputDirectory`: Directory where mosaics will be saved
- `progress`: Optional progress callback (completed count, total count)

**Returns**: Array of URLs to the generated mosaic files

**Status**: ✅ Fully implemented

---

### MetalMosaicGenerator

Metal-accelerated mosaic generator (actor).

```swift
@available(macOS 15, iOS 18, *)
public actor MetalMosaicGenerator
```

#### Initializer

```swift
public init(layoutProcessor: LayoutProcessor = LayoutProcessor()) throws
```

**Parameters**:
- `layoutProcessor`: The layout processor to use (optional)

**Throws**: Error if Metal processor initialization fails

#### Methods

##### generate(for:config:forIphone:)

Generate a mosaic for a video using Metal acceleration.

```swift
public func generate(
    for video: VideoInput,
    config: MosaicConfiguration,
    forIphone: Bool = false
) async throws -> URL
```

**Parameters**:
- `video`: The video to generate a mosaic for
- `config`: The configuration for mosaic generation
- `forIphone`: Whether to use iPhone-optimized layout (default: false)

**Returns**: The URL of the generated mosaic image

**Throws**: `MosaicError` on failure

##### cancel(for:)

Cancel mosaic generation for a specific video.

```swift
public func cancel(for video: VideoInput)
```

**Parameters**:
- `video`: The video to cancel mosaic generation for

##### cancelAll()

Cancel all ongoing mosaic generation operations.

```swift
public func cancelAll()
```

##### setProgressHandler(for:handler:)

Set a progress handler for a specific video.

```swift
public func setProgressHandler(
    for video: VideoInput,
    handler: @escaping @Sendable (Double) -> Void
)
```

**Parameters**:
- `video`: The video to set the progress handler for
- `handler`: The progress handler (receives 0.0 to 1.0)

##### getPerformanceMetrics()

Get performance metrics for the Metal mosaic generator.

```swift
public func getPerformanceMetrics() -> [String: Any]
```

**Returns**: A dictionary of performance metrics

---

### MosaicGeneratorCoordinator

Coordinator for batch mosaic generation operations (actor).

```swift
@available(macOS 15, iOS 18, *)
public actor MosaicGeneratorCoordinator
```

#### Initializer

```swift
public init(
    mosaicGenerator: MetalMosaicGenerator? = nil,
    modelContext: ModelContext,
    concurrencyLimit: Int = 4,
    generatorType: MosaicGeneratorFactory.GeneratorType = .metal
)
```

**Parameters**:
- `mosaicGenerator`: The mosaic generator to use (optional)
- `modelContext`: The SwiftData model context
- `concurrencyLimit`: Maximum number of concurrent generation tasks (default: 4)
- `generatorType`: The type of mosaic generator to use (default: .metal)

#### Methods

##### generateMosaic(for:config:forIphone:progressHandler:)

Generate a mosaic for a single video.

```swift
public func generateMosaic(
    for video: VideoInput,
    config: MosaicConfiguration,
    forIphone: Bool = false,
    progressHandler: @escaping @Sendable (MosaicGenerationProgress) -> Void
) async throws -> MosaicGenerationResult
```

**Parameters**:
- `video`: The video to generate a mosaic for
- `config`: The configuration for mosaic generation
- `forIphone`: Whether to use iPhone-optimized layout
- `progressHandler`: Handler for progress updates

**Returns**: The result of mosaic generation

##### generateMosaicsforbatch(videos:config:forIphone:progressHandler:)

Generate mosaics for multiple videos.

```swift
public func generateMosaicsforbatch(
    videos: [VideoInput],
    config: MosaicConfiguration,
    forIphone: Bool = false,
    progressHandler: @escaping @Sendable (MosaicGenerationProgress) -> Void
) async throws -> [MosaicGenerationResult]
```

**Parameters**:
- `videos`: Array of videos to process
- `config`: The configuration for mosaic generation
- `forIphone`: Whether to use iPhone-optimized layout
- `progressHandler`: Handler for progress updates

**Returns**: Array of generation results

##### cancelGeneration(for:)

Cancel mosaic generation for a specific video.

```swift
public func cancelGeneration(for video: VideoInput)
```

##### cancelAllGenerations()

Cancel all ongoing mosaic generation operations.

```swift
public func cancelAllGenerations()
```

---

### LayoutProcessor

Handles mosaic layout calculations and optimization.

```swift
@available(macOS 15, iOS 18, *)
public final class LayoutProcessor
```

#### Initializer

```swift
public init(aspectRatio: CGFloat = 16.0 / 9.0)
```

#### Methods

##### calculateLayout(...)

Calculate optimal mosaic layout.

```swift
public func calculateLayout(
    originalAspectRatio: CGFloat,
    mosaicAspectRatio: AspectRatio,
    thumbnailCount: Int,
    mosaicWidth: Int,
    density: DensityConfig,
    useCustomLayout: Bool,
    useAutoLayout: Bool = false,
    useDynamicLayout: Bool = false,
    forIphone: Bool = false
) -> MosaicLayout
```

**Returns**: Optimal layout for the mosaic

##### calculateThumbnailCount(duration:width:density:useAutoLayout:)

Calculate thumbnail count based on video duration and width.

```swift
public func calculateThumbnailCount(
    duration: Double,
    width: Int,
    density: DensityConfig,
    useAutoLayout: Bool = false
) -> Int
```

**Returns**: Optimal number of thumbnails

##### updateAspectRatio(_:)

Update the mosaic aspect ratio.

```swift
public func updateAspectRatio(_ ratio: CGFloat)
```

---

## Models

### VideoInput

A simplified video input model for mosaic generation.

```swift
public struct VideoInput: Codable, Hashable, Sendable
```

#### Properties

```swift
public let id: UUID
public let url: URL
public let title: String
public let duration: TimeInterval?
public let width: Double?
public let height: Double?
public let frameRate: Double?
public let fileSize: Int64?
public let metadata: VideoMetadata
```

#### Computed Properties

```swift
public var resolution: CGSize?
public var aspectRatio: Double?
```

#### Initializers

```swift
// Initialize with explicit values
public init(
    id: UUID = UUID(),
    url: URL,
    title: String? = nil,
    duration: TimeInterval? = nil,
    width: Double? = nil,
    height: Double? = nil,
    frameRate: Double? = nil,
    fileSize: Int64? = nil,
    metadata: VideoMetadata = VideoMetadata()
)

// Initialize from URL with automatic metadata extraction
public init(from url: URL) async throws
```

---

### VideoMetadata

Metadata about a video file.

```swift
public struct VideoMetadata: Codable, Hashable, Sendable
```

#### Properties

```swift
public var codec: String?
public var bitrate: Int64?
public var custom: [String: String]
```

#### Initializer

```swift
public init(
    codec: String? = nil,
    bitrate: Int64? = nil,
    custom: [String: String] = [:]
)
```

---

### MosaicLayout

A model representing the layout of a mosaic.

```swift
public struct MosaicLayout: Codable, Sendable
```

#### Properties

```swift
public let rows: Int
public let cols: Int
public let thumbnailSize: CGSize
public let positions: [Position]
public let thumbCount: Int
public let thumbnailSizes: [CGSize]
public let mosaicSize: CGSize
```

#### Methods

```swift
public func drawMosaicASCIIArt() -> String
```

---

### MosaicGenerationResult

Result of mosaic generation.

```swift
@available(macOS 15, iOS 18, *)
public struct MosaicGenerationResult: Sendable
```

#### Properties

```swift
public let video: VideoInput
public let outputURL: URL?
public let error: Error?
public var isSuccess: Bool
```

---

### MosaicGenerationProgress

Progress information for mosaic generation.

```swift
@available(macOS 15, iOS 18, *)
public struct MosaicGenerationProgress: Sendable
```

#### Properties

```swift
public let video: VideoInput
public let progress: Double
public let status: MosaicGenerationStatus
public let outputURL: URL?
public let error: Error?
```

---

### MosaicGenerationStatus

Status of mosaic generation.

```swift
@available(macOS 15, iOS 18, *)
public enum MosaicGenerationStatus: Sendable
```

#### Cases

```swift
case queued
case inProgress
case completed
case failed
case cancelled
```

---

## Configuration

### MosaicConfiguration

Configuration for mosaic generation.

```swift
public struct MosaicConfiguration: Codable, Sendable
```

#### Properties

```swift
public var width: Int                      // Default: 5120
public var density: DensityConfig          // Default: .default
public var format: OutputFormat            // Default: .heif
public var layout: LayoutConfiguration     // Default: .default
public var includeMetadata: Bool           // Default: true
public var useAccurateTimestamps: Bool     // Default: true
public var compressionQuality: Double      // Default: 0.4
public var outputdirectory: URL?           // Default: nil
```

#### Initializer

```swift
public init(
    width: Int = 5120,
    density: DensityConfig = .default,
    format: OutputFormat = .heif,
    layout: LayoutConfiguration = .default,
    includeMetadata: Bool = true,
    useAccurateTimestamps: Bool = true,
    compressionQuality: Double = 0.4,
    ourputdirectory: URL? = nil
)
```

#### Static Properties

```swift
public static var `default`: MosaicConfiguration
```

---

### DensityConfig

Density configuration for frame extraction.

```swift
public struct DensityConfig: Equatable, Hashable, Codable, Sendable
```

#### Properties

```swift
public let name: String
public let factor: Double
public let extractsMultiplier: Double
public let thumbnailCountDescription: String
```

#### Static Properties

```swift
public static let xxl: DensityConfig  // factor: 0.25
public static let xl: DensityConfig   // factor: 0.5
public static let l: DensityConfig    // factor: 0.75
public static let m: DensityConfig    // factor: 1.0 (default)
public static let s: DensityConfig    // factor: 2.0
public static let xs: DensityConfig   // factor: 3.0
public static let xxs: DensityConfig  // factor: 4.0

public static let allCases: [DensityConfig]
public static let `default`: DensityConfig  // Same as .m
```

---

### LayoutConfiguration

Configuration for mosaic layout settings.

```swift
public struct LayoutConfiguration: Codable, Sendable
```

#### Properties

```swift
public var aspectRatio: AspectRatio
public var spacing: CGFloat
public var useAutoLayout: Bool
public var useCustomLayout: Bool
public var visual: VisualSettings
```

#### Initializer

```swift
public init(
    aspectRatio: AspectRatio = .widescreen,
    spacing: CGFloat = 4,
    useAutoLayout: Bool = false,
    useCustomLayout: Bool = true,
    visual: VisualSettings = .default
)
```

#### Static Properties

```swift
public static let `default`: LayoutConfiguration
```

---

### AspectRatio

Predefined aspect ratios for mosaic layout.

```swift
public enum AspectRatio: String, Codable, Sendable
```

#### Cases

```swift
case widescreen = "16:9"   // 16:9 aspect ratio
case standard = "4:3"      // 4:3 aspect ratio
case square = "1:1"        // 1:1 aspect ratio
case ultrawide = "21:9"    // 21:9 aspect ratio
case vertical = "9:16"     // 9:16 aspect ratio (portrait)
```

#### Properties

```swift
public var ratio: CGFloat
```

#### Static Properties

```swift
public static let allCases: [AspectRatio]
```

---

### OutputFormat

The output format for mosaic images.

```swift
public enum OutputFormat: String, Codable, Sendable
```

#### Cases

```swift
case jpeg  // JPEG format
case png   // PNG format
case heif  // HEIF format (High Efficiency Image Format)
```

#### Properties

```swift
public var fileExtension: String  // "jpg", "png", or "heic"
```

---

### VisualSettings

Visual settings for mosaic layout.

```swift
public struct VisualSettings: Codable, Sendable
```

#### Properties

```swift
public var addBorder: Bool
public var borderColor: BorderColor
public var borderWidth: CGFloat
public var addShadow: Bool
public var shadowSettings: ShadowSettings?
```

#### Static Properties

```swift
public static let `default`: VisualSettings
```

---

### ShadowSettings

Shadow settings for frames.

```swift
public struct ShadowSettings: Codable, Sendable
```

#### Properties

```swift
public let opacity: CGFloat
public let radius: CGFloat
public let offset: CGSize
```

#### Static Properties

```swift
public static let `default`: ShadowSettings
```

---

## Errors

### MosaicError

Errors that can occur during mosaic generation.

```swift
public enum MosaicError: LocalizedError
```

#### Cases

```swift
case layoutCreationFailed(Error)
case imageGenerationFailed(Error)
case saveFailed(URL, Error)
case invalidDimensions(CGSize)
case invalidConfiguration(String)
case generationFailed(Error)
case fileExists(URL)
case contextCreationFailed
case imageCreationFailed
case invalidVideo(String)
case metalNotSupported
case processingFailed(String)
```

#### Properties

```swift
public var errorDescription: String?
```

---

### LibraryError

Errors that can occur during library operations.

```swift
public enum LibraryError: LocalizedError
```

#### Cases

```swift
case itemCreationFailed(String)
case itemDeletionFailed(String)
case itemMoveFailed(String)
case itemUpdateFailed(String)
case itemNotFound(String)
case operationNotSupported(String)
case operationFailed(String)
```

---

## Factory

### MosaicGeneratorFactory

A factory for creating mosaic generators.

```swift
@available(macOS 15, iOS 18, *)
public enum MosaicGeneratorFactory
```

#### Types

```swift
public enum GeneratorType: String, Codable {
    case metal = "Metal"
}
```

#### Methods

```swift
public static func createGenerator() throws -> MetalMosaicGenerator
public static func getGeneratorInfo() -> [String: Any]
```

---

## Notes

- All async methods support Swift's structured concurrency
- Actors (`MetalMosaicGenerator`, `MosaicGeneratorCoordinator`) provide thread-safe access
- Progress handlers use `@Sendable` closures for Swift 6 concurrency safety
- Metal availability is required for all generators

---

## Version

API Version: 1.0.0
Last Updated: 2025
