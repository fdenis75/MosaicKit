# MosaicKit – CLAUDE.md

This file helps AI assistants understand the MosaicKit codebase, development workflows, and conventions.

---

## Project Overview

**MosaicKit** is a Swift package that generates video mosaics (contact-sheet style image grids) and
preview videos from video files on Apple platforms (macOS 15+, iOS 15+, macCatalyst 15+).

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

### Dual-engine design

MosaicKit has two concrete generator implementations behind a shared protocol:

| Class | Platform | Backend |
|---|---|---|
| `MetalMosaicGenerator` | macOS | Metal GPU (actor-isolated) |
| `CoreGraphicsMosaicGenerator` | iOS / universal | Core Graphics + vImage/Accelerate |

`MosaicGeneratorFactory` picks the right implementation at runtime. The public convenience wrapper
`MosaicKit.swift` / `MosaicGenerator` hides this behind `.auto`, `.preferMetal`,
`.preferCoreGraphics` preferences.

### Key types

| Type | File | Role |
|---|---|---|
| `MosaicGenerator` | `Sources/MosaicKit.swift` | Public entry point |
| `MosaicGeneratorProtocol` | `Processing/MosaicGeneratorProtocol.swift` | Shared interface |
| `MetalMosaicGenerator` | `Processing/MetalMosaicGenerator.swift` | macOS Metal engine (actor) |
| `CoreGraphicsMosaicGenerator` | `Processing/CoreGraphicsMosaicGenerator.swift` | iOS/CPU engine |
| `MosaicGeneratorCoordinator` | `Processing/MosaicGeneratorCoordinator.swift` | Concurrent batch manager |
| `LayoutProcessor` | `Processing/LayoutProcessor.swift` | Layout calculation + caching |
| `ThumbnailProcessor` | `Processing/ThumbnailProcessor.swift` | Frame extraction |
| `MetalImageProcessor` | `Processing/MetalImageProcessor.swift` | Metal shader dispatch |
| `CoreGraphicsImageProcessor` | `Processing/CoreGraphicsImageProcessor.swift` | vImage-based processing |
| `VideoMetadataExtractor` | `Processing/VideoMetadataExtractor.swift` | AVFoundation metadata |
| `PreviewVideoGenerator` | `Processing/Preview/PreviewVideoGenerator.swift` | Highlight reel generation |
| `MosaicConfiguration` | `Models/MosaicConfiguration.swift` | Main config struct |
| `DensityConfig` | `Models/DensityConfig.swift` | Frame density levels |
| `LayoutConfiguration` | `Models/LayoutConfiguration.swift` | Layout settings |
| `AspectRatio` | `Models/AspectRatio.swift` | Predefined ratios |

### Generation pipeline

1. Extract video metadata (AVAsset / `VideoMetadataExtractor`)
2. Extract frames (VideoToolbox hardware acceleration via `ThumbnailProcessor`)
3. Calculate layout (`LayoutProcessor` – cached)
4. Process images (Metal shaders or Core Graphics / vImage)
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

Do not add new dependencies without a clear justification. Prefer built-in Apple frameworks.

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
- `GettingStarted.md` – quick onboarding
- `LayoutAlgorithms.md` – layout algorithm details
- `Architecture.md` – system architecture overview
- `PlatformStrategy.md` – Metal vs Core Graphics strategy
- `PerformanceGuide.md` – optimization guidance

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
2. Handle encoding in both `MetalMosaicGenerator` and `CoreGraphicsMosaicGenerator`
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
