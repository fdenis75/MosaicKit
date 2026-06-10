# MosaicKit – CLAUDE.md

This file helps AI assistants understand the MosaicKit codebase, development workflows, and conventions.

---

## Project Overview

**MosaicKit** is a Swift package that generates video mosaics (contact-sheet style image grids) and
preview videos from video files on Apple platforms (macOS 26+, iOS 26+, macCatalyst 26+).

- **Language**: Swift 6.2
- **Build system**: Swift Package Manager (SPM)
- **License**: Apache 2.0

---

## Repository Layout

```
MosaicKit/
├── Sources/
│   ├── Models/            # Codable configuration & data structs
│   ├── Processing/        # Core generation logic
│   │   └── Preview/       # Preview video generation
│   ├── Shaders/           # Metal GPU compute kernels (.metal)
│   └── MosaicKit.docc/    # DocC documentation catalog
├── Tests/
│   └── MosaicKitTests/    # Swift Testing unit/integration tests
├── Examples/              # Standalone example executables
├── Media.xcassets/        # Bundled test video asset
├── Package.swift          # SPM manifest (Swift 6.2)
├── Package.resolved       # Dependency lock file
├── README.md
├── DOCUMENTATION.md
└── CONTRIBUTING.md
```

---

## Architecture

### Single Metal engine

MosaicKit uses a single Metal GPU backend on all platforms (macOS, iOS, macCatalyst):

| Class | Platform | Backend |
|---|---|---|
| `MetalMosaicGenerator` | macOS, iOS, macCatalyst | Metal GPU (actor-isolated) |

`MetalMosaicGenerator` is the sole public entry point and conforms to `MosaicGeneratorProtocol`.
There is no factory or platform-selection wrapper — construct it directly.

### Key types

| Type | File | Role |
|---|---|---|
| `MetalMosaicGenerator` | `Processing/MetalMosaicGenerator.swift` | Metal engine (actor, all platforms) — main entry point |
| `MosaicGeneratorProtocol` | `Processing/MosaicGeneratorProtocol.swift` | Shared interface |
| `MosaicGeneratorCoordinator` | `Processing/MosaicGeneratorCoordinator.swift` | Concurrent batch manager |
| `LayoutProcessor` | `Processing/LayoutProcessor.swift` | Layout calculation + caching |
| `ThumbnailProcessor` | `Processing/ThumbnailProcessor.swift` | Frame extraction |
| `MetalImageProcessor` | `Processing/MetalImageProcessor.swift` | Metal shader dispatch |
| `AnimatedGifGenerator` | `Processing/AnimatedGifGenerator.swift` | Animated GIF/HEICS/WebP export |
| `VideoMetadataExtractor` | `Processing/VideoMetadataExtractor.swift` | AVFoundation metadata |
| `scanVideos(in:recursive:)` | `VideoInputScanner.swift` | Directory scan → `[VideoInput]` |
| `PreviewVideoGenerator` | `Processing/Preview/PreviewVideoGenerator.swift` | Highlight reel generation |
| `PreviewGeneratorCoordinator` | `Processing/Preview/PreviewGeneratorCoordinator.swift` | Concurrent preview batch manager |
| `FFmpegEncoder` | `Processing/Preview/FFmpegEncoder.swift` | Passthrough export + ffmpeg transcode (macOS only) |
| `AppLifecycleMonitor` | `Processing/Preview/AppLifecycleMonitor.swift` | Foreground-wait gating for background-safe export |
| `MosaicConfiguration` | `Models/MosaicConfiguration.swift` | Main config struct |
| `FFmpegEncodingOptions` | `Models/FFmpegEncodingOptions.swift` | Codec/CRF/preset options for `PreviewExportMode.ffmpeg` |
| `DensityConfig` | `Models/DensityConfig.swift` | Frame density levels |
| `LayoutConfiguration` | `Models/LayoutConfiguration.swift` | Layout settings |
| `AspectRatio` | `Models/AspectRatio.swift` | Predefined ratios |

### Generation pipeline

1. Extract video metadata (AVAsset / `VideoMetadataExtractor`)
2. Extract frames (VideoToolbox hardware acceleration via `ThumbnailProcessor`)
3. Calculate layout (`LayoutProcessor` – cached)
4. Process images (Metal GPU shaders via `MetalImageProcessor`)
5. Extract dominant colors (`DominantColors` package → smart background)
6. Compose final mosaic with optional metadata overlay
7. Encode & save (HEIF / JPEG / PNG via `VideoFormat`)

---

## Models & Configuration

All model types are `Codable` and `Sendable`.

### `MosaicConfiguration`
The primary configuration object. Key fields:
- `density: DensityConfig` – controls how many frames are extracted
- `layout: LayoutConfiguration` – layout algorithm and target size
- `format: VideoFormat` – output file format (`.heic`, `.jpg`, `.png`)
- `compression` – quality settings per format
- `gifMode: GifCreationMode` – `.disabled` / `.withMosaic` / `.gifOnly` animated export
- `gifSize: GifSize`, `animatedFormat: AnimatedFormat` (`.gif`/`.heic`/`.webp`), `gifFps: Double`
  (default `10`) – control the animated export produced by `AnimatedGifGenerator`

### `DensityConfig` (7 levels)
`XXL` (0.25×) → `XL` (0.5×) → `L` (0.75×) → **`M` (1.0× default)** → `S` (2.0×) → `XS` (3.0×) → `XXS` (4.0×)

### `LayoutConfiguration` (5 layout types)
- `custom` – three-zone (small top/bottom, large center) **[default]**
- `classic` – uniform grid
- `auto` – screen-aware automatic selection
- `dynamic` – center-emphasized variable sizing
- `iPhone` – mobile-optimized

### `AspectRatio` (5 presets)
`16:9`, `4:3`, `1:1`, `21:9`, `9:16`

---

## Preview Export Modes

`PreviewConfiguration.exportMode: PreviewExportMode` selects how previews are encoded:

| Mode | Behavior |
|---|---|
| `.native` | AVAssetExportSession (default) |
| `.sjs` | `SJSAssetExportSession` for resolution downscaling |
| `.ffmpeg` | Passthrough export to a temp `.mov`, then transcode via an external `ffmpeg` binary |

`.ffmpeg` is **macOS-only** and requires `PreviewConfiguration.ffmpegBinaryPath` to point at a valid,
executable `ffmpeg` (validated fail-fast before composition starts). `ffmpegEncodingOptions`
(`FFmpegEncodingOptions`) controls codec/CRF/preset/resolution; when `nil` it's derived from
`compressionQuality`. `ffmpegTempFolder` defaults to an auto-cleaned UUID dir under
`/tmp/MosaicKitFFmpeg/`.

`PreviewConfiguration.enableAppLifecycleMonitor` (default `true`) and `enableExportRetry` (default
`true`) control foreground-wait gating and stall-retry behavior — set both `false` for
daemons/XPC/CLI tools where the app never becomes foreground.

---

## Concurrency Model

- `MetalMosaicGenerator` is a Swift **actor** – all mutable state is actor-isolated.
- `MosaicGeneratorCoordinator` manages concurrent batch jobs with CPU/memory-aware limits.
- All public API is `async throws`.
- Use `Task { }` for fire-and-forget; propagate `CancellationError` where appropriate.
- Conform new types to `Sendable` when crossing actor boundaries.

---

## Error Handling

Custom error types conform to `LocalizedError` with `errorDescription`, `failureReason`, and
`recoverySuggestion`:

| Error type | File |
|---|---|
| `MosaicError` | `Processing/ProcessingError.swift` |
| `LibraryError` | `Processing/ProcessingError.swift` |
| `VideoError` | `Processing/VideoError.swift` |
| `PreviewError` | `Processing/Preview/PreviewError.swift` |

Always use these types rather than creating ad-hoc `NSError` or string-based errors.

---

## Logging

Use `swift-log` (`import Logging`). Logger subsystem is `com.mosaicKit`. Example:

```swift
private let logger = Logger(label: "com.mosaicKit.myComponent")
logger.info("Processing started", metadata: ["file": .string(url.lastPathComponent)])
```

Use `OSLog` signposts for performance-sensitive paths (the Metal pipeline uses these already).

---

## Platform-Specific Code

```swift
#if os(macOS)
// Metal / AppKit code
#else
// Core Graphics / UIKit code
#endif

#if canImport(AppKit)
// NSImage etc.
#elseif canImport(UIKit)
// UIImage etc.
#endif
```

Never use AppKit APIs in code that may run on iOS and vice versa. Always wrap.

---

## External Dependencies (Package.resolved)

| Package | Version | Use |
|---|---|---|
| `apple/swift-log` | ≥ 1.6.0 | Structured logging |
| `DominantColors` | ≥ 1.2.0 | Background color extraction from frames |
| `SJSAssetExportSession` | ≥ 0.4.0 | Enhanced AVAsset export (resolution downscaling) |
| `webp.swift` / `libwebp-ios` | ≥ 1.1.x | WebP encoding for `AnimatedGifGenerator` |

Do not add new dependencies without a clear justification. Prefer built-in Apple frameworks.

`PreviewExportMode.ffmpeg` additionally shells out to an external `ffmpeg` binary (path supplied via
`PreviewConfiguration.ffmpegBinaryPath`); this is a runtime dependency, not an SPM package.

---

## Testing

Framework: **Swift Testing** (`import Testing`).

```bash
swift test                          # Run all tests
swift test --filter <TestName>      # Run a specific test
swift test --parallel               # Parallel execution
swift test --enable-code-coverage   # Generate coverage
```

Test files live in `Tests/MosaicKitTests/`. Test assets are in `Tests/MosaicKitTests/embeddedAsset/`
and `Media.xcassets/`.

CI disables extended suites with:
```
MOSAICKIT_SUITE_MODE=none
```

When writing new tests:
- Use `@Test` and `#expect` / `#require` (Swift Testing macros).
- For async code use `@Test func myTest() async throws { … }`.
- Avoid hard-coded file paths; use bundle resources.

---

## Build Commands

```bash
swift build                              # Debug build
swift build -c release                   # Release build
swift package generate-documentation    # Build DocC docs
```

There is no Makefile. Everything goes through `swift`.

---

## Code Style Conventions

Follow Swift 6 best practices as documented in `CONTRIBUTING.md`.

- **Types**: PascalCase (`MetalMosaicGenerator`, `DensityConfig`)
- **Functions / variables**: camelCase
- **Error types**: `<Domain>Error` suffix
- **Actors**: used for any class with shared mutable state accessed concurrently
- **Structs over classes** for value-semantic data (all Model types are structs)
- **Protocol-first** design – add to the protocol before adding a concrete method
- Explicit access control (`public`, `internal`, `private`) on all declarations
- No `force_try` / `force_cast` in production code; use `guard let` or `try?` with fallback
- Keep files focused: one primary type per file

---

## Documentation

DocC catalog is at `Sources/MosaicKit.docc/`. Articles:
- `GettingStarted.md` / `QuickStart.md` – quick onboarding
- `LayoutAlgorithms.md` – layout algorithm details
- `Architecture.md` – system architecture overview
- `PlatformStrategy.md` – Metal vs Core Graphics strategy (historical context)
- `PerformanceGuide.md` – optimization guidance
- `PreviewExporting.md` – preview export modes (native/SJS/ffmpeg)

Update or add DocC articles when introducing new public API.

---

## CI/CD Workflows (`.github/workflows/`)

| File | Purpose |
|---|---|
| `swift.yml` | Basic build + test on macOS latest |
| `mosaickit-tests.yml` | Full matrix tests, Swift 6.2, SPM caching |
| `swift62.yml` | Swift 6.2-specific verification |
| `claude-code-review.yml` | Automated code review |
| `claude.yml` | Claude integration |

CI runs `swift build` then `swift test --parallel` on push/PR to `main`.

---

## Common Tasks

### Add a new layout type
1. Add case to `LayoutConfiguration` enum
2. Implement calculation in `LayoutProcessor.swift`
3. Update DocC article `LayoutAlgorithms.md`
4. Add tests in `MosaicGeneratorCoordinatorTests.swift` or a new test file

### Add a new output format
1. Add case to `VideoFormat` in `Models/VideoFormat.swift`
2. Handle encoding in `MetalMosaicGenerator` (mosaic still images) and/or
   `AnimatedGifGenerator` (animated formats)
3. Update `README.md` format table

### Add a new configuration option
1. Add to `MosaicConfiguration` (keep `Codable` and `Sendable`)
2. Thread it through the generator protocol and both implementations
3. Document it in README.md configuration reference section

### Run examples
```bash
swift run SimpleExample
swift run BasicExample
swift run BatchExample
swift run AdvancedExample
swift run PreviewCompositionExample
```
