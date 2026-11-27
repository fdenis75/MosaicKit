# Migrating to MosaicKit 2.0.0

This guide is for apps that already use MosaicKit 1.19.x. 2.0.0 adds an opt-in ffmpeg fallback for
sources AVFoundation can't read (macOS), and removes the API deprecated since 1.x.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| calls `TransportStreamRemuxer` | [2.2](#22-transportstreamremuxer-is-replaced) | Source break |
| uses API deprecated in 1.x, or `LayoutType.dynamic` | [2.3](#23-removed-api) | Source break |
| wants AVI, WMV, FLV, MKV, WebM and similar on macOS | [2.1](#21-ffmpegfallback) | Opt-in |
| runs on iOS or Mac Catalyst | [2.3](#23-removed-api) only | `enable` throws; `FFmpegFallback.isSupported` is `false` |

With the fallback off, generation behaves as in 1.19.0. Output names and `configurationHash` are
unchanged, except for configurations that used `.dynamic` ([2.3](#23-removed-api)).

## 2. Changes

### 2.1 `FFmpegFallback`

```swift
#if os(macOS)
try FFmpegFallback.enable(
    ffmpegBinaryPath: "/opt/homebrew/bin/ffmpeg",
    ffprobeBinaryPath: nil,          // default: the `ffprobe` next to `ffmpeg`
    cacheDirectory: nil,             // default: <temp>/MosaicKitFFmpegCache
    maximumCacheBytes: FFmpegFallback.defaultMaximumCacheBytes   // 20 GB
)
#endif
```

It is process-wide: call it once at startup. `disable()`, `clearCache()` and `isEnabled` complete
the API. MosaicKit doesn't ship ffmpeg; the app supplies the binary.

AVFoundation stays the default. Each source takes one route:

| Route | When | What happens |
|---|---|---|
| `.native` | AVFoundation decodes it | Unchanged |
| `.remuxed` | The codec is decodable but the container or file isn't (MKV, many AVI, HEVC in TS) | Video is copied into a cached MP4, without re-encoding |
| `.ffmpeg` | The codec isn't decodable (WMV, FLV, VP9) | ffmpeg decodes the frames and preview extracts; MosaicKit does the rest |

- **`FFmpegFallback.route(for:)`** says which route a URL takes. It never writes a file, so the
  `.remuxed` / `.ffmpeg` answer is a prediction from the codec. It returns `.native` without
  probing while the fallback is off.
- **Inspection** (`VideoInput(from:)`) never remuxes or copies: sources on a fallback route are
  described by `ffprobe`. Names, headers and metadata always describe the original file.
- **Audio** in a remux is copied if it is AAC, AC-3, E-AC-3 or ALAC, and re-encoded to AAC
  otherwise. It is dropped only if that fails too.
- **Previews** of an `.ffmpeg` source first encode only the chosen extracts (VideoToolbox) into
  temporary files, then compose them as usual. Timestamp overlays show source times.
- **Files without a usable index** (some AVI and FLV): when a seek near the end is slow, a
  Matroska copy is made in the cache first.
- **`reduceSourceReads`** doesn't apply to fallback routes, and `.ffmpeg` frames are always
  taken at their exact time. A remote `.remuxed` source is downloaded in full, once.
- **`scanVideos` / `discoverVideos`** also return `mpg`, `mpeg`, `vob`, `ogv`, `divx`, `rm`,
  `rmvb` and `dv` files, only while the fallback is on.
- **Cost.** While on, the first access to a file outside MP4/MOV decodes one frame to choose its
  route. The answer is cached per file.
- **HDR** sources on the `.ffmpeg` route are not tone-mapped.
- **Errors.** A source neither can read keeps AVFoundation's error. ffmpeg failures throw the
  existing typed errors (`VideoError`, `MosaicError`, `PreviewError`); cancellation stops ffmpeg.

### 2.2 `TransportStreamRemuxer` is replaced

| 1.19 | 2.0 |
|---|---|
| `TransportStreamRemuxer.enable(ffmpegBinaryPath:cacheDirectory:maximumCacheBytes:)` | `FFmpegFallback.enable(ffmpegBinaryPath:cacheDirectory:maximumCacheBytes:)` |
| `disable()`, `clearCache()`, `isEnabled`, `isSupported`, `defaultMaximumCacheBytes`, `defaultCacheDirectory` | Same names on `FFmpegFallback` |

Differences: `ffprobe` is now required too, and the default cache folder is
`<temp>/MosaicKitFFmpegCache` (delete `<temp>/MosaicKitRemux` if you want the space back).

### 2.3 Removed API

| Removed | Use instead |
|---|---|
| `GenerationJobController`, `GenerationJobID`, `GenerationAttemptID`, `GenerationJobState`, `GenerationJobSnapshot` | `MosaicGeneratorCoordinator`, or cancel your own `Task` |
| `generateallcombinations(for:config:)` | Call `generate(for:config:forIphone:)` per configuration |
| `ThumbnailProcessor.extractThumbnails`, `extractFramesStream`, `extractThumbnailsUI` | `MetalMosaicGenerator.extractThumbnails(for:options:)` |
| `ThumbnailProcessor.generateMosaic`, the `MetalImageProcessor.generateMosaic` array path | `MetalMosaicGenerator.generateMosaicImage(for:config:forIphone:)` |
| The legacy `createMetadataHeader(metadata:)` | `MetalMosaicGenerator.generate`, which draws the header |
| `MosaicLayout.drawMosaicASCIIArt()` | `description()` |
| `FFmpegEncodingOptions.forPreview(quality:)` | `from(quality:format:)` |
| `PreviewGeneratorCoordinator`'s unused getters | Keep the value you passed in |
| `LayoutType.dynamic` | `.custom` |

A saved configuration containing `"dynamic"` still decodes, as `.custom`. It was already laid out
that way, but its `configurationHash` and `{layout}` token now say `custom`, so its output path
changes once.

## 3. Tessera checklist

- Bump MosaicKit to `2.0.0` in `project.yml`.
- CLI and direct-download macOS app: call `FFmpegFallback.enable` instead of
  `TransportStreamRemuxer.enable`, when ffmpeg and ffprobe are found.
- App Store macOS and iOS: never call it.
- Library scans: add the extra extensions only when `FFmpegFallback.isEnabled`.
- Offer `clearCache()` or a custom `cacheDirectory` if users convert many files.
