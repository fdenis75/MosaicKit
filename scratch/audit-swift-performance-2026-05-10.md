# Swift Performance Audit — MosaicKit (2026-05-10)

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4 |
| HIGH | 8 |
| MEDIUM | 6 |
| LOW | 3 |

**Health: BOTTLENECKED**

---

## Performance Health Score

| Metric | Value |
|--------|-------|
| Value type efficiency | 3 large structs, 0 with ownership annotations (0%) |
| ARC discipline | 1 `@unchecked Sendable` race, 2 `[weak self]` patterns (legitimate) |
| Collection efficiency | 12 `.append()` loops, 0 with `reserveCapacity` (0%) |
| Actor efficiency | 2+ actor hops per video in batch; 0 batched progress calls |
| Hot path cleanliness | 5 hot paths, 1 free of amplified anti-patterns (20%) |

---

## CRITICAL — Full-Canvas CGContext Recreated Per Frame (O(N²) Pixel Work)

**File**: `Sources/Processing/CoreGraphicsImageProcessor.swift:485-537`

`compositeFrame(_:onto:in:visual:)` creates a brand-new `CGContext` at full mosaic dimensions for every single frame rendered, then draws the entire accumulated mosaic into it. For a 5120×2880 mosaic with 200 frames: 200 contexts × 56 MB = 11 GB of bitmap memory allocated and filled. Frame 200 redraws 199 frames of history — this is O(N²) pixel work.

**Fix**: Allocate the mosaic `CGContext` once before the loop, draw the background once, draw each frame into it directly. Call `makeImage()` once at the end.

---

## CRITICAL — `generateMosaicStream` Buffers All Frames Before GPU Rendering

**File**: `Sources/Processing/MetalImageProcessor.swift:840-849`

`generateMosaicStream` collects all N frames from the async stream into `var allFrames: [(Int, CGImage)] = []` before starting Metal rendering. All decoded thumbnail images (1–4 MB each as RGBA CGImages) are held in memory simultaneously. For a 400-frame high-density mosaic: 400–1600 MB of CGImage memory before the GPU sees any work. Defeats the entire purpose of the streaming architecture.

**Fix**: Process batches as they arrive from the async stream — fill the 20-frame batch and call `processBatch` immediately rather than waiting for stream completion.

---

## CRITICAL — Actor Hop × N in Batch Video Processing

**File**: `Sources/Processing/MosaicGeneratorCoordinator.swift:617-636`

Each TaskGroup child task calls `await self.generateMosaic(...)` (hop onto coordinator actor), which calls `await mosaicGenerator.setProgressHandler(...)` + `await mosaicGenerator.generate(...)` (two more hops). For 100 videos: 300 actor-executor transitions at startup + up to 6,000 per-frame progress update hops. Each hop is ~100μs.

**Fix**: Pass the generator reference directly into child tasks and bypass the coordinator actor for generation calls.

---

## CRITICAL — Data Race on `MetalImageProcessor` Metrics (`@unchecked Sendable`)

**File**: `Sources/Processing/MetalImageProcessor.swift:19, 1163-1168`

`MetalImageProcessor` is `@unchecked Sendable` with three mutable properties (`lastExecutionTime`, `totalExecutionTime`, `operationCount`) written from `trackPerformance(startTime:)` — called in `defer` blocks from every public method. When multiple TaskGroup child tasks call `renderFrame` concurrently, these are unsynchronized concurrent writes to shared state. Race suppressed by `@unchecked Sendable`.

**Fix**: Remove the metrics (duplicated in the actor wrappers), or protect with `Atomic<T>` from the `Synchronization` framework.

---

## HIGH — Missing `reserveCapacity` in All Layout Calculation Hot Paths

**File**: `Sources/Processing/LayoutProcessor.swift:284-320, 378-386, 493-496, 698-701`

All four layout methods build `positions` and `thumbnailSizes` arrays with repeated `.append()` and no prior `reserveCapacity`. For 800 elements: ~10 buffer reallocations per array per call.

**Fix**: Add `positions.reserveCapacity(thumbnailCount)` and `sizes.reserveCapacity(thumbnailCount)` before each loop in all four methods.

---

## HIGH — `CIContext` Created on Every Mosaic Generation

**Files**:
- `Sources/Processing/MetalImageProcessor.swift:617`
- `Sources/Processing/CoreGraphicsImageProcessor.swift:317`

`CIContext()` is instantiated inline inside `processImagesToMTLTexture` / `processImagesToBackground`. `CIContext` initialization compiles CI kernels and allocates GPU state (~50-100ms). For 100-video batch: 100-200 unnecessary `CIContext` instances created and discarded.

**Fix**: Cache as instance property: `private lazy var ciContext = CIContext(mtlDevice: device)` in `MetalImageProcessor`; `private lazy var ciContext = CIContext()` in `CoreGraphicsImageProcessor`.

---

## HIGH — Unstructured Producer Task Not Cooperatively Cancelled

**File**: `Sources/Processing/MetalMosaicGenerator.swift:212-244`

An unstructured `Task {}` producer feeds an `AsyncThrowingStream`. When the parent generation task is cancelled, the producer continues running (extracting frames, creating `CGImage`s, calling `continuation.yield`) until it naturally completes. No cooperative cancellation check in the producer loop.

**Fix**: Use `withTaskCancellationHandler` or check `Task.isCancelled` in the producer's frame loop. Model producer as a child task in `withThrowingTaskGroup` so cancellation propagates automatically.

---

## HIGH — `MosaicConfiguration` Unnecessarily Copied to Mutate One Field

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:145-146`
- `Sources/Processing/CoreGraphicsMosaicGenerator.swift:~383`

`var mutableConfig = config` copies the 15-property struct (including nested `OverlayConfiguration`, `LayoutConfiguration`, `MosaicColor`) just to call `updateAspectRatio(new:)`.

**Fix**: Compute the final aspect ratio inline without copying the struct, passing the computed value directly to downstream functions.

---

## HIGH — `ByteCountFormatter` Allocated Per-Call in Hot Path

**Files**:
- `Sources/Processing/ThumbnailProcessor.swift:1016-1021`
- `Sources/Processing/MetalImageProcessor.swift:1178`

`ByteCountFormatter()` instantiated fresh inside `formatBitrate(_:)` and `formatMetadata(_:)`. For 100-video batch: 200 formatter objects created and discarded.

**Fix**: `private static let bitrateFormatter: ByteCountFormatter = { ... }()` in both files.

---

## HIGH — `MosaicLayout` Passed by Value in Innermost Rendering Loop

**File**: `Sources/Processing/MetalImageProcessor.swift:958-1031`

`renderFrame(_:at:into:layout:visual:spacing:metadataHeight:commandBuffer:)` takes `MosaicLayout` by value — a struct with 3 COW array descriptors + 2 CGSizes. Called N times per mosaic (up to 800×). The arrays don't deep-copy (COW), but the struct header is stack-copied on each call.

**Fix**: Mark as `borrowing layout: borrowing MosaicLayout` to make intent explicit and suppress optimizer uncertainty.

---

## HIGH — Font-Shrink Loop Creates CTLine Per 0.5pt Step

**File**: `Sources/Processing/ThumbnailProcessor.swift:1448-1457`

The `shrinkToFit` path decrements font size by 0.5pt and creates a new `CTLine` + `TextLineMetrics` each iteration. Shrinking from 12pt to 7pt = 10 iterations × 2 CoreText allocations.

**Fix**: Replace linear 0.5pt steps with binary search between `minimumFontSize` and `currentFontSize`.

---

## HIGH — `print()` Calls in Production Metal Generation Path

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:150`
- `Sources/Processing/MetalImageProcessor.swift:702-703`

Three `print()` calls in the hot path. `print()` is synchronous, acquires a stdout lock, forces eager string interpolation. In batch mode: 100 videos × 3 prints = 300 synchronized stdout acquisitions.

**Fix**: Replace with `logger.debug(...)` — filtered at the logging subsystem level, O(1) overhead when disabled.

---

## HIGH — `MosaicGenerationProgress` Copies Full `VideoInput` Per Frame

**File**: `Sources/Processing/MetalMosaicGenerator.swift:258-265`

`MosaicGenerationProgress(video: video, ...)` copies the 13-property `VideoInput` (including `String`, `URL`, `VideoMetadata` with a `[String:String]` dictionary) inside the streaming progress handler, called 20–800 times per mosaic. For 400-frame mosaics: 400 `VideoInput` copies.

**Fix**: Remove `video` from the per-frame `MosaicGenerationProgress`, or capture only `videoID: UUID` for identification.

---

## MEDIUM — `layoutCache` in `LayoutProcessor` Is Never Populated (Dead Cache)

**File**: `Sources/Processing/LayoutProcessor.swift:16, 72-73`

`layoutCache: [String: MosaicLayout]` exists and is cleared in `updateAspectRatio` but never written. `calculateLayout` recomputes from scratch on every call. `generateAllCombinations` (21 calls) gets zero cache benefit.

**Fix**: Generate a stable cache key from `(aspectRatio, thumbnailCount, mosaicWidth, density, layoutType)` and populate the cache on every `calculateLayout` call.

---

## MEDIUM — Color Sort Allocates `[CGFloat]` Per Comparison

**Files**:
- `Sources/Processing/MetalImageProcessor.swift:557-563`
- `Sources/Processing/CoreGraphicsImageProcessor.swift:248-254`

The sort comparator uses `color.components ?? [0, 0, 0, 1]` — the `??` creates a temporary `[CGFloat]` heap array when `.components` is nil. ~120 potential array allocations per background generation.

**Fix**: Pre-extract brightness values into `[(CGColor, CGFloat)]` before sorting.

---

## MEDIUM — Dead `bufferPool` + `NSLock` in `CoreGraphicsImageProcessor`

**File**: `Sources/Processing/CoreGraphicsImageProcessor.swift:24-26, 44-52`

`bufferPool: [vImage_Buffer]` and `poolLock = NSLock()` are declared, cleaned up in `deinit`, but never used. Adds initialization overhead and misleads readers about thread safety.

**Fix**: Remove both (Option A), or implement the pool properly to reuse vImage buffers across scale operations (Option B — high value).

---

## MEDIUM — `calculateAutoLayout` Builds Full Arrays for Every Candidate Grid

**File**: `Sources/Processing/LayoutProcessor.swift:168-231`

For each `(rows, cols)` candidate (up to 120 iterations), full `positions` and `thumbnailSizes` arrays are built even though only the best layout is kept. 119 of 120 layouts are immediately discarded.

**Fix**: Separate scoring (no array allocation) from construction (one allocation for the winner).

---

## MEDIUM — `extractFramesWithVideoToolbox` Sorts Frames Unnecessarily

**File**: `Sources/Processing/MetalMosaicGenerator.swift:589`

`collected.sorted { $0.0 < $1.0 }` sorts frames after extraction, but `AVAssetImageGenerator.images(for:)` yields results in request order for sequential requests — the sort is unnecessary overhead.

**Fix**: Remove the sort. Use `currentIndex` to track order or insert into a pre-allocated array at the correct index.

---

## MEDIUM — `MosaicGenerationProgress` Struct Copies `VideoInput` on Every Update

See HIGH-8 above — also a MEDIUM structural issue: the `MosaicGenerationProgress` type design couples progress reporting to the full input model, causing allocation overhead throughout the pipeline.

---

## LOW — Identical Save Logic Copy-Pasted Between Both Generators

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:656-824`
- `Sources/Processing/CoreGraphicsMosaicGenerator.swift:517-693`

Identical `saveMosaic`/`saveAsHEIC`/`getJpegData`/`getPngData` logic between both generators. Any save-path bug must be fixed twice.

**Fix**: Extract to a `MosaicSaveHelper` with static functions.

---

## LOW — `formatTimestamp` Duplicated Between Two Files

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:631-636`
- `Sources/Processing/ThumbnailProcessor.swift:552-557`

Same implementation in both files.

**Fix**: Move to a shared extension on `TimeInterval`.

---

## LOW — Redundant `[weak self]` Pattern in `PreviewVideoGenerator`

**File**: `Sources/Processing/Preview/PreviewVideoGenerator.swift:98-100, 161-163`

Outer `[weak self]` capture is redundant when the inner `Task` also captures `[weak self]`. Since `PreviewVideoGenerator` is an actor, actors don't form retain cycles with closures — strong capture is safe and simpler.

---

## Quick Wins (1-line changes, high ROI)

1. **Cache `CIContext`** as instance property — saves 50–100ms per mosaic, seconds in batch
2. **Replace `print()` with `logger.debug()`** — eliminates stdout locking in hot path
3. **Add `reserveCapacity`** before all layout array builds — 8 one-line additions
4. **Implement `layoutCache` population** — eliminates repeated O(N) layout computation
5. **Fix `CoreGraphicsImageProcessor.compositeFrame`** — eliminates O(N²) pixel work on iOS

## Verification

- Profile with Instruments **Time Profiler** on a 100-video batch — the O(N²) issue shows as `CGContextDrawImage` dominating with time growing proportionally to frame index
- Profile with Instruments **Allocations** to verify peak memory reduction after fixing `generateMosaicStream` buffering
