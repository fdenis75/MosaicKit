# MosaicKit – AGENTS.md

This file tells AI assistants how to work in the MosaicKit codebase. It mirrors `CLAUDE.md`:
when you change one, make the same change to the other.

---

## Start here: the codebase knowledge base (mandatory)

[`codebase-analysis-docs/CODEBASE_KNOWLEDGE.md`](codebase-analysis-docs/CODEBASE_KNOWLEDGE.md) is
the map of this codebase: architecture, data flows, per-feature analysis, a verified issue
register, change checklists and a glossary. Diagrams are in `codebase-analysis-docs/assets/`.

**Before any work** (feature, fix, refactor, test or doc change), read:

1. The **Executive summary** and **§4.1 Rules card**. These are non-negotiable invariants.
2. The **Part 3** section of each feature you touch (F1–F13), plus **§3.14**, the cross-feature
   interaction matrix, to see what else your change affects.
3. **§4.2 Issue register** rows for that area. If you are fixing an issue, cite its ID (`I-n`) in
   the branch, commits and PR.
4. The matching **§4.8 Change checklist** (new config option, layout, format, preview mode, …).

**Planned work** (simplification and issue fixes) is sequenced in
[`codebase-analysis-docs/IMPLEMENTATION_PLAN.md`](codebase-analysis-docs/IMPLEMENTATION_PLAN.md),
with the maintainer decisions in knowledge base §6.4. Pick up the next unblocked item there,
follow its gates (⚡ = benchmark before/after, 📁 = output-naming change → changelog), and
update its §8 status row in your PR.

Also use **§4.3** for performance-sensitive work (throughput is a hard requirement: benchmark
against the current batched pipeline, and never regress it) and **§5** for API, schema, status
and error references.

**Source code is authoritative.** If the doc and the code disagree, trust the code and correct
the doc in the same PR.

**After any change, keep the doc current** (§6.3), in the same PR:

- **Fixed or found an issue:** update or add its §4.2 row (status column) and the matching
  §6.1 roadmap line. Keep IDs stable: never renumber, and add new issues as the next `I-n`.
- **Changed behavior, architecture or public API:** update the affected Part 2/Part 3 sections,
  §5.2 (API) and §5.6 (cookbook).
- **Run the checker:** `python3 codebase-analysis-docs/assets/doc_check.py`. It validates links,
  tables and fences, and re-hashes every `[[F:path#range#hash8]]` anchor. Re-verify every claim
  whose anchor it reports as changed, then update the anchor.
- **Don't edit** the per-phase wrap-up sections, except to mark corrections inline.

Other docs are less reliable (§1.9). `MosaicKit-DeepDive.md` describes a removed architecture:
don't use it. `spec.md` is design intent and only partly implemented.

---

## Project overview

**MosaicKit** is a Swift package that generates video mosaics (contact-sheet image grids),
animated previews (GIF / HEICS / WebP) and preview highlight-reel videos from video files on
Apple platforms (macOS 26+, iOS 26+, macCatalyst 26+).

- **Language**: Swift 6.2 (Swift 6 language mode)
- **Build system**: Swift Package Manager
- **License**: Apache 2.0
- **Products**:
  - `MosaicKit` (core).
  - `MosaicKitWebP` (opt-in WebP encoder). Call `MosaicKitWebP.register()` at startup. It is
    kept separate because its binary xcframework breaks Xcode SwiftUI Previews for every client
    that links it.

---

## Repository layout

```
MosaicKit/
├── Sources/                 # MosaicKit target
│   ├── Models/              # Codable, Sendable configuration & data types (+ validation)
│   ├── Processing/          # Mosaic engine, layout, frames, overlays, output publication
│   │   └── Preview/         # Preview video generation & export backends
│   ├── Shaders/             # Metal compute kernels (processed as a resource)
│   ├── VideoInputScanner.swift  # Directory discovery
│   └── MosaicKit.docc/      # DocC catalog
├── SourcesWebP/             # MosaicKitWebP target (webp.swift encoder, injected into core)
├── Tests/MosaicKitTests/    # Swift Testing suites + embeddedAsset/test_video.mp4
├── codebase-analysis-docs/  # Knowledge base (read first) + diagrams + doc_check.py
├── Examples/                # Reference snippets (not SPM targets, not built by CI)
├── Makefile, scripts/       # Xcode-project helpers (target a missing .xcodeproj) + scripts/task.sh
├── tasks/                   # Task backlog used by scripts/task.sh (see AGENTS.simple-tasks.md)
├── Media.xcassets/          # Xcode test asset (not used by the SPM tests)
├── Package.swift / Package.resolved
└── README.md, DOCUMENTATION.md, CONTRIBUTING.md, spec.md, MosaicKit-DeepDive.md (stale)
```

---

## Architecture (summary; details in knowledge base Part 2)

- **One Metal engine on every platform.** `MetalMosaicGenerator` (actor) is the mosaic entry
  point and conforms to `MosaicGeneratorProtocol`. There is no factory and no Core Graphics
  fallback engine.
- **Mosaic pipeline:**
  1. `VideoInput` / `VideoSource` inspection (`VideoMetadataExtractor`).
  2. Frame extraction: `ThumbnailProcessor.processedFramesStream`, batched
     `AVAssetImageGenerator` requests. The pull-based bounded source introduced in 1.7.0 was
     reverted because it was 30–45 % slower. `MosaicFrameSource` is currently unused (I-25).
  3. Layout (`LayoutProcessor`, cached).
  4. GPU composition in pipelined 20-frame Metal command buffers (`MetalImageProcessor`).
  5. Dominant-color background (`DominantColors`).
  6. Overlays (`OverlayProcessor`).
  7. Encode and publish through `OutputTransaction` (staging file + `rename`).
- **Animated export:** `AnimatedGifGenerator` writes GIF/HEICS via ImageIO, and WebP via the
  injected encoder. The frame delay is `1 / gifFps`.
- **Previews:** `PreviewVideoGenerator` (actor) composes a highlight reel and exports it with
  `.native` (AVAssetExportSession), `.sjs` (SJSAssetExportSession) or `.ffmpeg`.
- **Batches:** `MosaicGeneratorCoordinator` and `PreviewGeneratorCoordinator` (concurrency
  limits, `batchEpoch` cancellation). `GenerationJobController` provides an explicit job
  lifecycle.

### Key types

| Type | File | Role |
|---|---|---|
| `MetalMosaicGenerator` | `Processing/MetalMosaicGenerator.swift` | Mosaic engine (actor) |
| `MosaicGeneratorProtocol` | `Processing/MosaicGeneratorProtocol.swift` | Shared interface |
| `MosaicGeneratorCoordinator` | `Processing/MosaicGeneratorCoordinator.swift` | Concurrent mosaic batches |
| `GenerationJobController` | `Processing/GenerationJobs.swift` | Explicit job lifecycle |
| `LayoutProcessor` | `Processing/LayoutProcessor.swift` | Layout calculation + caching |
| `ThumbnailProcessor` | `Processing/ThumbnailProcessor.swift` | Frame extraction |
| `MetalImageProcessor` | `Processing/MetalImageProcessor.swift` | Metal shader dispatch |
| `OverlayProcessor` | `Processing/OverlayProcessor.swift` | Header, labels, watermark, ColorDNA |
| `AnimatedGifGenerator` | `Processing/AnimatedGifGenerator.swift` | GIF / HEICS / WebP export |
| `OutputTransaction` | `Processing/OutputTransaction.swift` | Staged output publication (shared by 5 features) |
| `VideoMetadataExtractor` | `Processing/VideoMetadataExtractor.swift` | AVFoundation metadata |
| `scanVideos(in:recursive:)` | `VideoInputScanner.swift` | Directory scan → `[VideoInput]` |
| `PreviewVideoGenerator` | `Processing/Preview/PreviewVideoGenerator.swift` | Highlight-reel generation |
| `PreviewGeneratorCoordinator` | `Processing/Preview/PreviewGeneratorCoordinator.swift` | Concurrent preview batches |
| `FFmpegEncoder` | `Processing/Preview/FFmpegEncoder.swift` | Passthrough export + ffmpeg transcode (macOS only) |
| `AppLifecycleMonitor` | `Processing/Preview/AppLifecycleMonitor.swift` | Foreground-wait gating for background-safe export |
| `MosaicConfiguration` | `Models/MosaicConfiguration.swift` | Main mosaic config (+ `OutputFormat`, `AnimatedFormat`, `GifSize`) |
| `PreviewConfiguration` | `Models/PreviewConfiguration.swift` | Preview config (+ `PreviewExportMode`) |
| Validation | `Models/ConfigurationValidation.swift` | All up-front config validation |
| `FFmpegEncodingOptions` | `Models/FFmpegEncodingOptions.swift` | Codec/CRF/preset options for `.ffmpeg` |
| `DensityConfig` | `Models/DensityConfig.swift` | Frame density levels |
| `LayoutConfiguration`, `LayoutType`, `AspectRatio` | `Models/LayoutConfiguration.swift` | Layout settings |
| `VideoInput`, `VideoSource` | `Models/VideoInput.swift`, `Models/VideoSource.swift` | Input identity & inspection |

---

## Models & configuration

Configuration and input models (`MosaicConfiguration`, `PreviewConfiguration`, `DensityConfig`,
layout, overlay and format types, `VideoInput`) are `Codable` and `Sendable`. Progress, result
and description types (`MosaicGenerationProgress`/`Result`, `PreviewGenerationProgress`/`Result`,
`PreviewCompositionResult`, `PreviewExportDescription`) are `Sendable` only; they carry `Error`
or `AVPlayerItem` values and must not be persisted. The full reference, with defaults, is in
knowledge base §5.2–§5.3.

- **`MosaicConfiguration`:**
  - `density` (default `.m`), `format: OutputFormat` (`.heif` default, `.jpeg`, `.png`,
    `.webp`), `layout`, `compressionQuality`, overlays.
  - Animation: `gifMode` (`.disabled` / `.withMosaic` / `.gifOnly`), `gifSize`,
    `animatedFormat` (`.gif` / `.heic` / `.webp`; the **default `.webp` needs
    `MosaicKitWebP.register()`**), `gifFps` (default `10`).
- **`DensityConfig`** (7 levels): `XXL` 0.25× → `XL` 0.5× → `L` 0.75× → **`M` 1.0× (default)** →
  `S` 2.0× → `XS` 3.0× → `XXS` 4.0×.
- **`LayoutType`:**
  - `custom`: three-zone, **default**.
  - `classic`: uniform grid.
  - `auto`: screen-aware; broken on iPhone, see I-9.
  - `dynamic`: center-emphasized; geometrically broken, see I-8.
  - `iphone`: mobile-optimized.
- **`AspectRatio`:** `16:9`, `4:3`, `1:1`, `21:9`, `9:16`.
- **Codable rule:** add new keys with `decodeIfPresent` plus a default. `MosaicConfiguration`'s
  decoder is strict, so a required new key breaks configs saved by older versions (I-24).
- **Persisted values:** never rename raw values that are persisted. They also appear in output
  paths through `configurationHash` (rules card #3–#4).

---

## Preview export modes

`PreviewConfiguration.exportMode: PreviewExportMode`:

| Mode | Behavior |
|---|---|
| `.native` (default) | AVAssetExportSession |
| `.sjs` | `SJSAssetExportSession`, for resolution downscaling |
| `.ffmpeg` | Passthrough export to a temp `.mov`, then transcode with an external `ffmpeg` binary |

- **`.ffmpeg` requirements:**
  - It is **macOS-only**.
  - `ffmpegBinaryPath` must point at an executable, and it is validated before composition
    starts.
  - `ffmpegEncodingOptions` is derived from `compressionQuality` when `nil`.
  - `ffmpegTempFolder` defaults to a UUID directory under
    `FileManager.default.temporaryDirectory/MosaicKitFFmpeg/`, cleaned up afterwards.
- **Background and CLI use:** `enableAppLifecycleMonitor` and `enableExportRetry` both default
  to `true`. Set both to `false` for daemons, XPC services and CLI tools that never become
  foreground.

---

## Concurrency & cancellation

- `MetalMosaicGenerator` and `PreviewVideoGenerator` are **actors**. Generation entry points are
  `async throws`. Cancellation, progress-handler and metrics methods (`cancel(for:)`,
  `cancelAll()`, `setProgressHandler`, `getPerformanceMetrics()`) are synchronous
  actor-isolated methods; keep them that way. Types that cross actor boundaries must be
  `Sendable`.
- Tracked tasks inherit the generator actor's isolation. **Don't add synchronous heavy work or
  blocking calls** (`waitUntilCompleted`, semaphores) to async code: they serialize jobs and
  starve the cooperative pool (rules card #6).
- Internal work runs in *tracked* unstructured tasks (`activeTasks` / `generationTasks`, keyed
  by video ID). Every `try await task.value` on a tracked task must be wrapped in
  `withTaskCancellationHandler` with `onCancel: { task.cancel() }`, because unstructured tasks
  don't inherit the caller's cancellation.
- `PreviewVideoGenerator` bridges task cancellation into its `CancellationToken`s, which the
  export watchdogs and phase checks poll.
- Coordinators keep a `batchEpoch` counter. `cancelAllGenerations()` bumps it, and a cancelled
  batch stops dequeuing and throws `CancellationError`. Cancelling a single video only fails
  that video's result.
- Long loops (frame extraction, animated encoding, `generateallcombinations`) must call
  `try Task.checkCancellation()` on every iteration.
- Report cancelled work with the `.cancelled` status, never `.failed`.

---

## Error handling

Use the existing typed errors, never ad-hoc `NSError` or string errors. Validation errors are
thrown from `Models/ConfigurationValidation.swift`.

| Error type | File |
|---|---|
| `MosaicError` | `Processing/ProcessingError.swift` |
| `LibraryError` | `Processing/ProcessingError.swift` (currently unused, I-25) |
| `VideoError` | `Processing/VideoError.swift` |
| `PreviewError` | `Processing/Preview/PreviewError.swift` |
| `MetalProcessorError` | `Processing/MetalImageProcessor.swift` |
| `MosaicKitWebPError` | `Processing/WebPSupport.swift` |

---

## Logging

The code uses **OSLog**, not swift-log. `swift-log` is declared in `Package.swift` but never
imported (I-23).

```swift
import OSLog
private let logger = Logger(subsystem: "com.mosaicKit", category: "my-component")
logger.info("Processing started: \(url.lastPathComponent, privacy: .public)")
```

- Use the subsystem **`com.mosaicKit`**. Some preview files still use `com.mosaickit` (I-23).
- Use signposts for performance-sensitive paths.

---

## Platform-specific code

- Metal runs on every platform. Guard `Process`/ffmpeg and other macOS-only APIs with
  `#if os(macOS)`.
- Use `#if canImport(AppKit)` / `#elseif canImport(UIKit)` for image types.
- **Test code must also compile on iOS:** the iOS CI job builds the tests. For example, use
  `URL.homeDirectory`, not `homeDirectoryForCurrentUser`.

---

## External dependencies

| Package | Version | Use |
|---|---|---|
| `DominantColors` | ≥ 1.2.0 | Background color extraction |
| `SJSAssetExportSession` | ≥ 0.4.0 | `.sjs` preview export |
| `webp.swift` (→ `libwebp-ios`) | ≥ 1.1.2 | WebP encoding, **`MosaicKitWebP` target only**; core never imports `webp` |
| `apple/swift-log` | ≥ 1.6.0 | Declared but unused (I-23) |

- Don't add dependencies without a clear justification. Prefer Apple frameworks.
- `.ffmpeg` shells out to an external `ffmpeg` binary. That is a runtime dependency, not an SPM
  package.

---

## Testing

Framework: **Swift Testing** (`import Testing`).

```bash
swift build --build-tests && swift test --skip-build   # what macOS CI runs
swift test --filter <TestName>
MOSAICKIT_SUITE_MODE=none swift test                    # CI mode: skip extended suites
```

- **Throughput benchmark (plan P-1):** `BenchmarkTests` runs only when `MOSAICKIT_BENCHMARK`
  points at a folder of videos (or one file). Every change tagged ⚡ in the implementation plan
  needs a before/after run on the same machine, pasted into the PR:
  `MOSAICKIT_BENCHMARK=/path/to/videos swift test -c release --filter BenchmarkTests`.
  Optional: `MOSAICKIT_BENCHMARK_RUNS` (default 3), `MOSAICKIT_BENCHMARK_CONCURRENCY`
  (default `1,0`), `MOSAICKIT_BENCHMARK_JSON` (write results as JSON).

- **Location:** tests live in `Tests/MosaicKitTests/`. The embedded fixture is
  `embeddedAsset/test_video.mp4`, loaded with `Bundle.module`.
- **Fixture format:** keep test videos **8-bit 4:2:0**. iOS cannot decode 10-bit H.264 (I-22).
- **`MOSAICKIT_SUITE_MODE`:** `none` skips media-folder and extended suites. That includes the
  108-run "create all versions" animated matrix. Prefer the `.enabled(if:)` trait over silently
  passing.
- **New tests:**
  - Use `@Test` with `#expect` / `#require`, and `async throws` for async code.
  - Don't hard-code file paths.
  - Keep per-test runtime small. The whole suite runs in about 40 s on macOS and about 4 min on
    the iOS Simulator; keep it that way.

---

## Build commands

```bash
swift build                              # Debug build
swift build -c release                   # Release build
swift package generate-documentation     # DocC
```

Everything goes through `swift`. The `Makefile` (and its `scripts/xcbuild.sh` helper) targets an
Xcode project that isn't in the repo, so it doesn't work as is.

---

## Code style

Follow `CONTRIBUTING.md`.

- **Naming:**
  - Types are PascalCase; functions and variables are camelCase.
  - Error types use the `<Domain>Error` suffix.
- **Type design:**
  - Use actors for shared mutable state.
  - Use structs for value types (all models are structs).
  - Design protocol-first.
- **Access control:** make it explicit on all declarations.
- **Safety:** no force-try or force-cast in production code.
- **Files:** one primary type per file.

---

## Documentation

- **Knowledge base:** `codebase-analysis-docs/CODEBASE_KNOWLEDGE.md`. Keep it current, as
  described in the first section of this file.
- **DocC** (`Sources/MosaicKit.docc/`):
  - `GettingStarted`, `QuickStart`: onboarding.
  - `LayoutAlgorithms`: layout types.
  - `Architecture`: accurate, but shows the array-based path.
  - `PerformanceGuide`: benchmarks unverified.
  - `PreviewExporting`: preview export modes.
  - `BackgroundProcessing`: iOS background execution.
  - `PlatformStrategy`: historical context.
- **When you add public API:** update DocC, `README.md` and knowledge base §5.2/§5.6.

---

## CI/CD (`.github/workflows/`)

| File | Purpose |
|---|---|
| `swift.yml` | macOS: `swift build --build-tests` + `swift test --skip-build`. iOS Simulator: `xcodebuild build-for-testing` / `test-without-building` on the `MosaicKit-Package` scheme. Both set `MOSAICKIT_SUITE_MODE=none`; iOS gets it as `TEST_RUNNER_MOSAICKIT_SUITE_MODE`. |
| `claude-code-review.yml` | Automated PR review. Runs only when code changes: `**/*.swift`, `**/*.metal`, `Package.resolved`, `Makefile`, `scripts/**`, `**/*.xctestplan`. |
| `claude.yml` | `@claude` mentions |

CI runs on pushes to `main` and `claude/**`, and on PRs to `main`.

---

## Common tasks

Follow the matching checklist in knowledge base §4.8. In short:

- **New configuration option:**
  1. Add the field (`Codable`, `Sendable`, `decodeIfPresent` + default).
  2. Validate it in `ConfigurationValidation.swift`.
  3. Thread it through `MetalMosaicGenerator` and/or `PreviewVideoGenerator`.
  4. Document it in README and knowledge base §5.2.
- **New layout type:**
  1. Add a `LayoutType` case.
  2. Implement it in `LayoutProcessor.swift`.
  3. Update DocC `LayoutAlgorithms.md`.
  4. Add tests in `LayoutProcessorTests.swift`.
- **New output format:**
  1. Add an `OutputFormat` case (still images) or an `AnimatedFormat` case (animations);
     preview containers use `VideoFormat` in `Models/VideoFormat.swift`.
  2. Handle encoding in `MetalMosaicGenerator` or `AnimatedGifGenerator`.
  3. Update the README format table.
- **Fixing a register issue (`I-n`):**
  1. Read its row and fix sketch.
  2. Add a regression test.
  3. Update the row's status, the §6.1 roadmap line and the plan's §8 row.
  4. Run `doc_check.py`.
