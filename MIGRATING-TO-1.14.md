# Migrating to MosaicKit 1.14.0

This guide is for apps that already use MosaicKit 1.13.x. 1.14.0 adds a public thumbnail
extraction API. Nothing is removed or renamed, mosaic output does not change, and output names do
not change.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| extracts frames itself with `AVAssetImageGenerator` | [2.1](#21-thumbnail-extraction-on-metalmosaicgenerator) | New API, opt-in |
| calls the deprecated `ThumbnailProcessor.extractThumbnails`, `extractFramesStream` or `extractThumbnailsUI` | [2.2](#22-deprecated-thumbnailprocessor-helpers) | Deprecation message changed; no behavior change |
| conforms its own type to `MosaicGeneratorProtocol` | — | None: the protocol is unchanged |

## 2. Source and behavior changes

### 2.1 Thumbnail extraction on `MetalMosaicGenerator`

Three new methods extract frames without building a mosaic:

```swift
let options = ThumbnailExtractionOptions(count: 12, maximumSize: CGSize(width: 640, height: 640))
let thumbnails = try await generator.extractThumbnails(for: video, options: options)      // [VideoThumbnail]
let images = try await generator.extractThumbnailImages(for: video, options: options)     // [CGImage]
let export = try await generator.exportThumbnails(for: video, options: options)           // files in a new temp directory
defer { try? FileManager.default.removeItem(at: export.directory) }
```

- `ThumbnailExtractionOptions`: `count` (1…10 000, default 10), `maximumSize` (`nil` keeps the
  display size), `sampling` (`.uniform` default, or `.weighted` as mosaics use), `accurate`
  (default `false`, ±1 s), `format` (default `.jpeg`) and `compressionQuality` (default 0.8) for
  files. It is `Codable`; every key is optional when decoding.
- Frames are raw (no timestamp label) and upright (the track transform is applied).
- Strict: an undecodable frame throws `MosaicError.processingFailed`. Invalid options throw
  `MosaicError.invalidConfiguration` before any decode; `.webp` files without
  `MosaicKitWebP.register()` throw `MosaicKitWebPError.encoderNotRegistered`.
- Cancellation: `cancel(for:)` (same `VideoInput.id`), `cancelAll()` and cancelling the calling task
  throw `CancellationError`. A failed or cancelled export removes the files it wrote (never other
  files), its private temporary directory, and a caller directory only if that leaves it empty.
- `exportThumbnails(for:options:to:)` names files `<video name>_<number>.<ext>` from `_0001`, and
  replaces a file of the same name in the directory you pass.
- The methods are on `MetalMosaicGenerator` only, not on `MosaicGeneratorProtocol`, so existing
  conformances keep compiling.

### 2.2 Deprecated `ThumbnailProcessor` helpers

`ThumbnailProcessor.extractThumbnails(from:layout:asset:…)`, `extractFramesStream(…)` and
`extractThumbnailsUI(…)` stay deprecated (removed in 2.0). They need a `MosaicLayout` and burn
timestamp labels into the frames; their messages now point to
`MetalMosaicGenerator.extractThumbnails(for:options:)`.
