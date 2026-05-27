# Memory Leak Audit — MosaicKit (2026-05-10)

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH | 4 |
| MEDIUM | 3 |
| LOW | 1 |

**Health**: LEAKING

---

## Resource Ownership Map

| Owner | Has deinit | Task tracking | Notes |
|-------|-----------|---------------|-------|
| `MetalMosaicGenerator` (actor) | No | Partial — 2 untracked fire-and-forget Tasks | Owns frameCache, progressHandlers, generationTasks |
| `CoreGraphicsMosaicGenerator` (actor) | No | OK for happy path | Missing progressHandlers cleanup on error |
| `MosaicGeneratorCoordinator` (actor) | No | Broken for `generateMosaicImage` path | Task created but never stored in activeTasks |
| `PreviewGeneratorCoordinator` (actor) | No | activeTasks always empty | cancel API is silently inoperative |
| `PreviewVideoGenerator` (actor) | No | OK via CancellationToken | Well managed |
| `CoreGraphicsImageProcessor` | Yes | N/A | Only class with deinit; frees vImage pool |
| `MetalImageProcessor` | No | N/A | Metal resources auto-released via ARC |
| `ThumbnailProcessor` | N/A | Partial | Inner Task in extractFramesStream untracked |

---

## CRITICAL/HIGH — Untracked Producer Tasks in MetalMosaicGenerator

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:212`
- `Sources/Processing/MetalMosaicGenerator.swift:415`

Both `generate()` and `generateMosaicImage()` launch producer tasks with bare `Task { [processor, videoURL, layout, asset, ...] in ... }`. These tasks are not stored in `generationTasks`, not assigned to any variable, and not tracked anywhere.

When `cancel(for:)` or `cancelAll()` is called, the producer Task continues running — draining frames from the video, holding the continuation open, occupying AVFoundation decode pipeline slots until it naturally finishes or errors.

**Fix**:
```swift
let producerTask = Task { [processor, videoURL, layout, asset, ...] in
    // existing body
}
return try await withTaskCancellationHandler {
    try await metalProcessor.generateMosaicStream(...)
} onCancel: {
    producerTask.cancel()
    continuation.finish(throwing: CancellationError())
}
```

---

## HIGH — MosaicGeneratorCoordinator.generateMosaicImage Task Not Stored

**File**: `Sources/Processing/MosaicGeneratorCoordinator.swift:256`

`generateMosaicImage(for:config:forIphone:progressHandler:)` creates `let task = Task<MosaicGenerationImage, Error>(priority: .userInitiated) { ... }` but does **not** store it in `activeTasks`. `cancelGeneration(for:)` and `cancelAllGenerations()` cannot reach this task. Only `generateMosaic()` (line 221) correctly stores its task.

**Fix**: Store the task in `activeTasks` and clean up in a `defer` block.

---

## HIGH — PreviewGeneratorCoordinator Tasks Not Stored in activeTasks

**Files**: `Sources/Processing/Preview/PreviewGeneratorCoordinator.swift:64, 103`

`generatePreview(for:...)` and `generatePreviewComposition(for:...)` call the generator directly with `await` — neither wraps in a stored `Task` nor adds to `activeTasks`. The `activeTasks` dictionary is never populated; `cancelGeneration(for:)` calls `activeTasks[video.id]?.cancel()` on an always-empty dictionary. **The public cancel API is silently inoperative.**

**Fix**: Wrap calls in a `Task`, store in `activeTasks`, clean up with `defer`.

---

## HIGH — frameCache Has No Eviction Policy

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:44`
- `Sources/Processing/CoreGraphicsMosaicGenerator.swift:24`

`frameCache: [UUID: [CMTime: CGImage]]` entries are only removed by `cancel(for:)` / `cancelAll()`. The `generate()` defer block clears `progressHandlers[videoID]` but **not** `frameCache[videoID]`. A successful generation leaves stale CGImage cache entries indefinitely. (Currently the cache is never populated — dead code — but the cleanup gap means adding one cache-write line creates a permanent leak.)

**Fix**: Add `frameCache[videoID] = nil` to the `defer` block in `generate()` alongside `progressHandlers` cleanup. Consider replacing with `NSCache` for automatic memory-pressure eviction.

---

## MEDIUM — generateMosaicImage Doesn't Clean Up progressHandlers on Error

**Files**:
- `Sources/Processing/CoreGraphicsMosaicGenerator.swift:305`
- `Sources/Processing/MetalMosaicGenerator.swift:338`

Both `generateMosaicImage` implementations have no `defer { progressHandlers[videoID] = nil }`. If the method throws, the progress handler closure (which typically captures a view model) is retained indefinitely — until the next generation for the same ID overwrites it or `cancelAll()` is called.

**Fix**: Add `defer { progressHandlers[videoID] = nil }` at the start of both methods.

---

## MEDIUM — ThumbnailProcessor.extractFramesStream Untracked Inner Task

**File**: `Sources/Processing/ThumbnailProcessor.swift:241`

`extractFramesStream(from:layout:asset:accurate:)` spawns `Task { ... }` (line 241) to feed the `AsyncThrowingStream`. This task is not stored. If the consumer stops iterating (due to outer cancellation), the producer Task continues running through all requested timestamps, holding `AVURLAsset` and in-flight `CGImage` frames alive — potentially 100-200MB for a large mosaic.

**Fix**: Add `Task.isCancelled` check inside the generator loop, or use `withTaskCancellationHandler`.

---

## MEDIUM — progressHandlers Exposed as public var

**File**: `Sources/Processing/MosaicGeneratorCoordinator.swift:125`

`public var progressHandlers: [UUID: (MosaicGenerationProgress) -> Void] = [:]` allows external callers to add entries without the paired removal logic. Risk: external code bypasses lifecycle management.

**Fix**: Change to `private var` and expose a `setProgressHandler(for:handler:)` method.

---

## LOW — CoreGraphicsImageProcessor vImage Buffer Pool Has No Upper Bound

**File**: `Sources/Processing/CoreGraphicsImageProcessor.swift:24`

`private var bufferPool: [vImage_Buffer] = []` has no max size cap. Currently never populated (dead code), but if buffer reuse is added, the pool will grow without bound under high parallelism.

**Fix**: Add a capacity cap when implementing pool reuse.

---

## Compound Findings

### Compound HIGH — Two-Level Zombie Task Chain

`MetalMosaicGenerator` untracked producer Task (lines 212/415) + `ThumbnailProcessor.extractFramesStream` untracked inner Task (line 241) = three Tasks continue running after outer cancellation, holding `AVURLAsset`, `AsyncThrowingStream.Continuation`, and in-flight `CGImage` frames. Multiplies by the number of concurrently cancelled videos in batch workloads.

### Compound MEDIUM — progressHandler Retention + Missing Cleanup

Both `generateMosaicImage` implementations lack error-path cleanup. The coordinator cleans up at its level but the generator actors retain the closure independently. Generator actor keeps the view model alive even after coordinator has released its reference.

---

## Recommendations

### Immediate
1. Fix untracked producer Tasks in `MetalMosaicGenerator` (lines 212, 415)
2. Store Task in `MosaicGeneratorCoordinator.generateMosaicImage()` (line 256)
3. Fix `PreviewGeneratorCoordinator` single-video paths — make cancel API work

### Short-Term
4. Add `defer { progressHandlers[videoID] = nil }` to both `generateMosaicImage()` implementations
5. Add `frameCache[videoID] = nil` to `defer` blocks in both `generate()` methods
6. Reduce `progressHandlers` visibility to `private var`

### Long-Term
7. Establish consistent lifecycle protocol across all resource-owning actors
8. Replace `frameCache` dict with `NSCache` for automatic memory-pressure eviction
9. Profile with Instruments Allocations — cancel 10 videos mid-batch, verify CGImage/AVURLAsset counts drop immediately
