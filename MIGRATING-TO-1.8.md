# Migrating to MosaicKit 1.8.0

This guide is for apps that already use MosaicKit 1.7.x (the last 1.7 release is 1.7.4). It lists
every change in 1.8.0 that can break or change the behavior of code that uses the library, who is
affected, how to tell, and what to change.

**Short version.** 1.8.0 has **one source-level break** (`MosaicGeneratorCoordinator.activeTasks`
is read-only), **five behavior changes** that can affect running code, and a set of
**deprecations** that only produce compiler warnings. Most apps need no changes. Read section 1
first to see which parts apply to you.

Every statement below was checked against the code at tag `1.7.4` and tag `1.8.0`. The public API
surface (every `public` declaration) differs between the two tags in one place only: `activeTasks`.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| assigns to, or removes from, `MosaicGeneratorCoordinator.activeTasks` | [2.1](#21-mosaicgeneratorcoordinatoractivetasks-is-read-only) | **Build error** |
| processes portrait phone videos and uses `VideoInput.width` / `height`, or swaps them itself | [3.1](#31-rotated-portrait-sources-report-display-dimensions) | Wrong sizes or wrong layout |
| calls `ffmpeg` preview export (`exportMode: .ffmpeg`) | [3.2](#32-ffmpeg-preview-export-aspect-ratio-frame-rate-pixel-format) | Different output files |
| starts several mosaic jobs for the same video at once | [3.3](#33-concurrent-mosaic-jobs-on-the-same-video-are-tracked-separately) | Different cancellation behavior |
| matches on `PreviewError.encodingFailed` to detect a cancelled export | [3.4](#34-a-cancelled-native-or-passthrough-export-reports-previewerrorcancelled) | Cancelled exports no longer look like failures |
| filters Console or log output on the subsystem `com.mosaickit` | [3.5](#35-the-log-subsystem-is-now-commosaickit-everywhere) | Missing log lines |
| imports `Logging` (swift-log) without declaring it yourself | [4](#4-swift-log-is-no-longer-a-dependency) | Build error |
| builds with warnings as errors, or calls any deprecated API | [5](#5-deprecations-removed-in-20) | Build error only with `-warnings-as-errors` |

Nothing else changes for you. In particular:

- **No output file names or locations change in 1.8.0.** (A naming change is planned for a later
  release and will be announced.)
- **Defaults do not change.** The default export resolution is `1080p`, as in 1.7.x.
- **Saved configurations still decode**, and more of them do: JSON saved by any release since
  1.0.0 now decodes, with later keys falling back to their defaults.
- **Throughput is unchanged** within measurement noise (the refactors in this release each passed a
  before/after benchmark).

## 2. Source-level breaks (your code stops compiling)

### 2.1 `MosaicGeneratorCoordinator.activeTasks` is read-only

In 1.7.x it was a stored property:

```swift
public var activeTasks: [UUID: Task<MosaicGenerationResult, Error>] = [:]
```

In 1.8.0 it is a computed property with no setter. The coordinator now tracks one task per
**attempt**, not per video, and `activeTasks` is a snapshot keyed by video ID (see
[3.3](#33-concurrent-mosaic-jobs-on-the-same-video-are-tracked-separately)). If several attempts
run on one video, the snapshot holds one of them.

**You are affected** if you write to it:

```swift
coordinator.activeTasks[video.id] = nil             // error: cannot assign through subscript
coordinator.activeTasks = [:]                       // error: cannot assign to property
coordinator.activeTasks.removeValue(forKey: video.id)
```

**Fix.** Use the cancellation methods, which cancel the tracked work and clean up for you:

```swift
await coordinator.cancelGeneration(for: video)   // every attempt on that video
await coordinator.cancelAllGenerations()         // everything, including queued batch work
```

Reading still compiles and still returns the in-flight tasks, so
`coordinator.activeTasks[video.id]?.cancel()` keeps working. Prefer `cancelGeneration(for:)`, which
also reaches attempts that `activeTasks` does not show.

If you used `activeTasks` to answer "is this video being processed?", keep that state in your own
code, keyed by what you started, for example from your progress handler (`.queued` → `.completed`
/ `.failed` / `.cancelled`).

## 3. Behavior changes (your code compiles, but results can differ)

### 3.1 Rotated (portrait phone) sources report display dimensions

**What changed.** Inspection (`VideoInput(from:)`, `VideoSource.inspect`) used to store the
stored size of the video track, for example 1920×1080 for a phone clip recorded in portrait with a
90° rotation flag. It now applies the track's `preferredTransform`, so it stores the displayed
size, 1080×1920. The header "Resolution" field follows the same values.

**Why.** Frames were already extracted upright, but the layout was computed for landscape cells, so
every portrait frame was stretched into a landscape cell (I-1).

**You are affected if:**

- you read `VideoInput.width` / `height` for rotated videos and assume `width > height` (aspect
  ratio, orientation tests, UI sizing, "is this portrait?" checks);
- you worked around the old behavior by swapping width and height yourself. After the upgrade the
  swap is wrong and the cells are rotated twice.

**Fix.**

```swift
// 1.7.x workaround: remove it
let transform = try await track.load(.preferredTransform)
let rotated90 = abs(transform.b) == 1 && abs(transform.c) == 1
let (w, h) = rotated90 ? (video.height, video.width) : (video.width, video.height)

// 1.8.0: video.width / video.height are already the displayed size
let aspectRatio = (video.width ?? 1) / (video.height ?? 1)
let isPortrait = (video.height ?? 0) > (video.width ?? 0)
```

If you **supply your own** `width` / `height` when you create a `VideoInput`, MosaicKit uses your
values as given (inspection never overrides what you passed). Pass the displayed size, that is
`naturalSize` with `preferredTransform` applied (absolute values).

**What you will see.** Mosaics of rotated videos now have portrait cells and a different overall
shape than before. Existing files are not touched: mosaics already on disk keep their stretched
look until you regenerate them (set `overwrite = true`, or delete them). Landscape videos are
unchanged.

### 3.2 ffmpeg preview export: aspect ratio, frame rate, pixel format

These affect only `PreviewConfiguration(exportMode: .ffmpeg)`. Native and SJS exports are
unchanged.

| What | 1.7.x | 1.8.0 |
|---|---|---|
| Scaling | Each axis clamped separately, so a source that did not match the cap's aspect ratio was **stretched** (3840×1600 capped at 1080p came out 1920×1080) | Aspect ratio is kept and dimensions are rounded down to even numbers (the same source comes out 1920×800); the cap is swapped for portrait sources |
| HEVC frame rate (`.hevc`, `.hevcVideoToolbox`) | Always resampled to **30 fps** (`-r 30`) | The **source frame rate** is kept (24, 25, 50, 60 fps stay as they are) |
| HEVC pixel format | `p010le` for both HEVC encoders | `yuv420p10le` for libx265 (`.hevc`), `p010le` stays for VideoToolbox (`.hevcVideoToolbox`) |
| Short ffmpeg runs | Could hang forever after ffmpeg exited | Fixed (I-27): the exit status comes from a termination handler |

**You are affected if** you pin or compare exported files: file size or bitrate expectations,
fixed output dimensions, a pipeline that assumes 30 fps, or a test that asserts the text of
`ExportMaxResolution.scaleFilter` (the filter string changed).

**Fix.** Update the expectations. If you need a fixed frame rate, set it in your own
`FFmpegEncodingOptions` or post-process the file. If you need an exact pixel size, pick a cap that
matches your sources' aspect ratio. The new pixel format was checked with ffmpeg 9; with an older
ffmpeg, run one export before shipping.

### 3.3 Concurrent mosaic jobs on the same video are tracked separately

**What changed.** `MosaicGeneratorCoordinator` used to key tasks, cancellation and progress
handlers by video ID. Starting a second job for a video that was already running overwrote the
first job's entries, so cancelling or finishing one could leave the other untracked or clobber its
handler. Now every attempt has its own entry (I-15).

**You are affected if** you start the same video more than once at the same time (for example a
"regenerate" button while a job runs, or two batches that overlap):

- `cancelGeneration(for: video)` now cancels **every** concurrent attempt on that video. Before,
  it reached the most recent one.
- Each attempt's progress handler is its own, so both keep reporting. Before, one could replace
  the other.
- Known limit: `MetalMosaicGenerator.setProgressHandler(for:)`, the per-stage handler on the
  generator itself, is still keyed by video. Two concurrent attempts on one video can swap that
  per-stage callback. The coordinator's own handlers are not affected.

**Fix.** Usually none. If a UI action must cancel only the newest attempt, hold a reference to
the task you started instead of cancelling by video.

### 3.4 A cancelled native or passthrough export reports `PreviewError.cancelled`

**What changed.** The native (`AVAssetExportSession`) and the ffmpeg passthrough exports now share
one stall and cancellation watchdog (`ExportWatchdog`, S-4). If the export fails because the task
was cancelled, the outcome is `PreviewError.cancelled`. In 1.7.x that case could surface as
`PreviewError.encodingFailed("Export failed", CancellationError())`, while the SJS path already
reported `.cancelled`. Stall detection is unchanged (`PreviewError.exportStalled`, after 120 s
without progress on macOS and 60 s on iOS for the native and SJS exports, 120 s for passthrough).

**You are affected if** your error handling treats `.encodingFailed` as "show an error" and
`.cancelled` as "stay silent", or retries on `.encodingFailed`. A user cancel that used to be
shown as a failure, or retried, is now handled as a cancel.

**Fix.** Handle both outcomes explicitly:

```swift
do {
    let url = try await generator.generate(for: video, config: config)
} catch PreviewError.cancelled {
    // user cancelled: no error UI, no retry
} catch is CancellationError {
    // same, if your own task was cancelled
} catch PreviewError.exportStalled(let seconds) {
    // see the "macOS background scheduling" note in the PreviewExporting article
} catch {
    // real failure
}
```

### 3.5 The log subsystem is now `com.mosaicKit` everywhere

Preview components used to log under `com.mosaickit` (all lowercase), the rest under
`com.mosaicKit`. Everything now uses `com.mosaicKit`. OSLog subsystem filters are case-sensitive.

**Fix.** Change Console filters, `log stream --predicate 'subsystem == "com.mosaickit"'` commands
and `OSLogStore` queries to `com.mosaicKit`.

## 4. swift-log is no longer a dependency

`swift-log` was declared in `Package.swift` but never imported by MosaicKit. 1.8.0 removes it from
the manifest and from `Package.resolved`.

**You are affected only if** your own code does `import Logging` without declaring swift-log
itself, so that it resolved only because MosaicKit pulled it in. Most projects are not affected.

**Fix.** Add the dependency to your own `Package.swift` (or your Xcode package list):

```swift
.package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
// and in your target:
.product(name: "Logging", package: "swift-log"),
```

Run `swift package resolve` (or File ▸ Packages ▸ Resolve Package Versions) after upgrading.

## 5. Deprecations (removed in 2.0)

Each of these still works unchanged in 1.8.0. They produce a compiler **warning** that names the
replacement. They break only if your build treats warnings as errors
(`-warnings-as-errors`, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`); either migrate now or exclude
`DeprecatedDeclaration` from the warnings-as-errors set until you do.

| Deprecated | Replace with |
|---|---|
| `GenerationJobController`, `GenerationJobID`, `GenerationAttemptID`, `GenerationJobState`, `GenerationJobSnapshot` (cancel and retry are incomplete, I-14) | `MosaicGeneratorCoordinator` or `PreviewGeneratorCoordinator` (batch methods, `cancelGeneration(for:)`, `cancelAllGenerations()`) |
| `generateallcombinations(for:config:)` on `MetalMosaicGenerator` and `MosaicGeneratorProtocol` (ignores most of its configuration) | Call `generate(for:config:forIphone:)` once per configuration |
| `ThumbnailProcessor.extractThumbnails`, `extractFramesStream`, `extractThumbnailsUI`, `generateMosaic` | `MetalMosaicGenerator.generateMosaicImage(for:config:forIphone:)` for a mosaic, or `AVAssetImageGenerator` for raw frames |
| `ThumbnailProcessor.createMetadataHeader(metadata:…)` (legacy) | `createMetadataHeader(for:width:height:thumbnailHeight:backgroundColor:forIphone:headerConfig:swatchColors:)` |
| `MetalImageProcessor.generateMosaic(from:…)` (array-based path) | `MetalMosaicGenerator.generateMosaicImage(for:config:forIphone:)` |
| `MosaicLayout.drawMosaicASCIIArt()` | `description()` |
| `FFmpegEncodingOptions.forPreview(quality:)` | `FFmpegEncodingOptions.from(quality:format:)`, or build the options yourself with `videoCodec: .hevcVideoToolbox` |
| `PreviewGeneratorCoordinator.getConcurrencyLimit()` and `getActiveGenerationCount()` | Keep the value you passed to `init(concurrencyLimit:)` / `setConcurrencyLimit(_:)`, and count in-flight work from your progress handlers |

Find your uses by building once on 1.8.0 and filtering the build log for "deprecated". Fixing them
now means the 2.0 upgrade needs no code changes.

## 6. Upgrade checklist

1. Change the dependency to `from: "1.8.0"` and resolve packages.
2. Build. Fix any `activeTasks` assignment ([2.1](#21-mosaicgeneratorcoordinatoractivetasks-is-read-only))
   and, if you use swift-log yourself, add it explicitly ([4](#4-swift-log-is-no-longer-a-dependency)).
3. Grep your code for `width`/`height` swaps around `VideoInput` ([3.1](#31-rotated-portrait-sources-report-display-dimensions))
   and remove them.
4. If you use `.ffmpeg` export, run one export per source type (landscape, portrait, 24/25/60 fps)
   and compare size and frame rate with your expectations ([3.2](#32-ffmpeg-preview-export-aspect-ratio-frame-rate-pixel-format)).
5. Review your error handling for preview export cancellation ([3.4](#34-a-cancelled-native-or-passthrough-export-reports-previewerrorcancelled)).
6. Update Console filters to `com.mosaicKit` ([3.5](#35-the-log-subsystem-is-now-commosaickit-everywhere)).
7. Read the deprecation warnings and migrate at your pace ([5](#5-deprecations-removed-in-20)).
8. Regenerate (with `overwrite = true`) any mosaics of rotated videos you want to fix.

## 7. Known issue in 1.8.0

Native preview export (`AVAssetExportSession`) can stall when macOS runs your process under
background scheduling (I-26). The failure is reported as `PreviewError.exportStalled`, and the
export succeeds once the process runs at normal priority. Apps and command-line tools should leave
background scheduling before exporting. The details and measurements are in the
`PreviewExporting` article, section "macOS Background Scheduling".
