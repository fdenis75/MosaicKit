# Swift Concurrency Audit — MosaicKit (2026-05-10)

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4 |
| HIGH | 6 |
| MEDIUM | 5 |
| LOW | 2 |

**Swift 6 Readiness: NOT READY**

---

## Isolation Architecture Map

MosaicKit uses a **per-type actor isolation** strategy with no global `@MainActor` default. Key actors: `MetalMosaicGenerator`, `CoreGraphicsMosaicGenerator`, `MosaicGeneratorCoordinator<G>`, `PreviewVideoGenerator`, `PreviewGeneratorCoordinator`, `VideoMetadataExtractor`.

`ThumbnailProcessor`, `MetalImageProcessor`, `CoreGraphicsImageProcessor`, and `LayoutProcessor` are **`final class` with `@unchecked Sendable`** — not actors, protect state via `NSLock` or leave it unprotected.

## Concurrency Health Score

| Metric | Value |
|--------|-------|
| Isolation coverage | ~55% — actors covered; `ThumbnailProcessor`, `MetalImageProcessor`, `CoreGraphicsImageProcessor`, `LayoutProcessor`, `MosaicGenerator` are unannotated `@unchecked Sendable` classes |
| Structured concurrency | ~70% — batch paths use TaskGroup; inner producers use unstructured Task |
| Escape hatches | 5 `@unchecked Sendable`, 3 `@preconcurrency` imports, 1 `nonisolated(unsafe)` |
| Cancellation coverage | ~40% — actor `activeTasks` dicts store tasks but no auto-cleanup on actor deallocation |
| GCD legacy | 0 DispatchQueue usages |

---

## CRITICAL — Unstructured Producer Task Escapes Actor Isolation Without Error Handling

**Files**:
- `Sources/Processing/MetalMosaicGenerator.swift:212`
- `Sources/Processing/MetalMosaicGenerator.swift:415`

Fire-and-forget `Task { ... }` inside actor methods feeds an `AsyncThrowingStream`. This task:
1. Has no error handling — if it fails unexpectedly the `continuation` may never finish and the consuming `for try await` loop hangs forever
2. Inherits the actor's executor — serializing frame extraction + Metal processing on the actor, starving it from handling cancellations
3. Has no connection to Swift structured concurrency — outer task cancellation doesn't reach it

**Fix**: Use `continuation.onTermination` to cancel the producer, or use `async let` / `TaskGroup` siblings.

---

## CRITICAL — `@unchecked Sendable` on `MetalImageProcessor` with Mutable Unprotected State

**File**: `Sources/Processing/MetalImageProcessor.swift:19`

`MetalImageProcessor` is `@unchecked Sendable` but has three mutable `private var` fields: `lastExecutionTime`, `totalExecutionTime`, `operationCount`. Written from `trackPerformance(startTime:)` called in `defer` blocks. Because the producer Task and `generateMosaicStream` run concurrently inside `MetalMosaicGenerator`, these vars are accessed from multiple concurrent execution contexts without synchronization.

**Fix**: Use `Mutex` / `OSAllocatedUnfairLock`, make the type an actor, or move metric tracking into `MetalMosaicGenerator`.

---

## CRITICAL — `@unchecked Sendable` on `ThumbnailProcessor` Masking Concurrent Access Risks

**File**: `Sources/Processing/ThumbnailProcessor.swift:16`

`ThumbnailProcessor: @unchecked Sendable` uses `[self]` captures inside `group.addTask { [self] in ... }` at lines 82 and 123. Current `let` properties are safe, but `@unchecked` removes all future compiler guarantees.

**Fix**: Remove `@unchecked` — all stored properties are `let` and `MosaicConfiguration` is `Sendable`, so plain `Sendable` conformance should compile cleanly.

---

## CRITICAL — Fire-and-Forget Task in `extractFramesStream` Has No Lifecycle Control

**File**: `Sources/Processing/ThumbnailProcessor.swift:241`

`extractFramesStream(from:layout:asset:accurate:)` spawns `Task { ... }` with no parent and no cancellation hookup. When the caller cancels, the producer Task continues extracting frames and yielding to a dead continuation.

**Fix**:
```swift
return AsyncThrowingStream { continuation in
    let task = Task { /* extraction logic */ }
    continuation.onTermination = { _ in task.cancel() }
}
```

---

## HIGH — `MosaicGenerator` Public Entry Point Not `Sendable`

**File**: `Sources/MosaicKit.swift:128`

`public final class MosaicGenerator` stores `private let internalGenerator: Any?`. Because `Any?` is not `Sendable`, `MosaicGenerator` can't conform to `Sendable`. Callers sharing an instance across actors get Swift 6 concurrency errors.

**Fix**: Replace `Any?` with `any MosaicGeneratorProtocol` (which is `Sendable` since the protocol requires `Actor`).

---

## HIGH — `LayoutProcessor` Is Mutable Class Shared Across Actors

**File**: `Sources/Processing/LayoutProcessor.swift:12`

`LayoutProcessor` has `public var mosaicAspectRatio: CGFloat` and `private var layoutCache: [String: MosaicLayout]`. Stored as `let` in both generator actors. Actor mutates `layoutProcessor.mosaicAspectRatio` directly. Not `Sendable`, so compiler should flag it when crossing actor boundaries (suppressed by `@preconcurrency`).

**Fix**: Make `LayoutProcessor` an actor, or add `Mutex` protection on mutable state.

---

## HIGH — `CoreGraphicsImageProcessor` `NSLock` Across Potential Await Points

**File**: `Sources/Processing/CoreGraphicsImageProcessor.swift:17`

`private var bufferPool: [vImage_Buffer]` guarded by `NSLock`. Holding `NSLock` across an `await` is a deadlock pattern. Current code doesn't do this, but `@unchecked Sendable` makes it invisible to the compiler.

**Fix**: Migrate to `Mutex<[vImage_Buffer]>` from the `Synchronization` framework (macOS 15+ / iOS 18+).

---

## HIGH — `MosaicGeneratorCoordinator` Inner Task Retain Cycle Risk

**File**: `Sources/Processing/MosaicGeneratorCoordinator.swift:177, 256`

`Task` closures capture `mosaicGenerator` (an actor) and the stored task goes into `activeTasks`. Creates: `MosaicGeneratorCoordinator → activeTasks → Task → (implicit self for logger) → MosaicGeneratorCoordinator`. Coordinator stays alive until all tasks complete even if callers release their reference.

**Fix**: Verify no implicit `self` capture in task closures. Use explicit capture lists.

---

## HIGH — `PreviewGenerationLogic.generate` and `generateComposition` Inconsistent Isolation

**File**: `Sources/Processing/Preview/PreviewVideoGenerator.swift:223, 306`

`generateComposition(...)` is annotated `@MainActor` (for AVFoundation safety). The sibling `generate(...)` doing the same AVFoundation operations has no isolation annotation.

**Fix**: Add `@MainActor` to `generate(...)` for consistency.

---

## HIGH — `nonisolated(unsafe)` Without Migration Comment

**File**: `Sources/Processing/Preview/PreviewVideoGenerator.swift:1115`

```swift
nonisolated(unsafe) let compositionAsset = composition as AVAsset
```
`AVMutableComposition` is non-Sendable. No comment explains why this is safe. `generate(...)` is not `@MainActor`, so the composition could be passed across executor boundaries.

**Fix**: Add isolation contract comment, or mark `generate(...)` as `@MainActor`.

---

## MEDIUM — `@preconcurrency` Imports Without Migration Plan

**Files**:
- `Sources/Processing/MosaicGeneratorCoordinator.swift:1,3`
- `Sources/Models/PreviewGenerationProgress.swift:8,9`

Three `@preconcurrency` imports (Foundation, CoreImage, AVFoundation) suppress concurrency warnings with no comments. `@preconcurrency import CoreImage` may be hiding a CGImage Sendability issue — `CGImage` is actually `Sendable` in modern SDK.

**Fix**: Remove `@preconcurrency import CoreImage`. Document what the AVFoundation/Foundation imports are suppressing.

---

## MEDIUM — CPU-Intensive Work Runs on Actor Executor Without `@concurrent`

Synchronous methods performing significant image processing (`addTimestampToImage`, `createMetadataHeader`, vImage operations, Metal setup) run on actor executors when called from actor-isolated methods. Under `withTaskGroup`, child tasks inherit the calling actor's isolation, blocking it.

**Fix**: Mark CPU-heavy methods with `@concurrent` (Swift 6.2+) to force them onto background threads.

---

## MEDIUM — `CancellationToken` and `ExportProgressTracker` Use `NSLock`

**File**: `Sources/Processing/Preview/PreviewVideoGenerator.swift:14, 33`

`NSLock` in `@unchecked Sendable` classes. Currently correct (no await inside locked regions), but fragile.

**Fix**: Migrate to `Mutex<Bool>` from the `Synchronization` framework.

---

## LOW — `@preconcurrency import AVFoundation` in Models File

**File**: `Sources/Models/PreviewGenerationProgress.swift:9`

A Models file (pure `Codable`/`Sendable` structs) imports AVFoundation with `@preconcurrency`. Likely needed for `AVPlayerItem` in `PreviewCompositionResult`. Should be isolated to its own file with explicit Sendability handling.

---

## Compound Findings

| Finding A | Finding B | Compound Severity |
|-----------|-----------|------------------|
| Unstructured producer Task in `MetalMosaicGenerator` | No cancellation propagation | CRITICAL — consumer loop can hang if producer dies silently |
| `@unchecked Sendable` on `MetalImageProcessor` | Mutable vars in concurrent defer blocks | CRITICAL — hidden data race on perf metrics |
| Missing `@concurrent` on `addTimestampToImage` | Called from TaskGroup tasks inside actor | HIGH — actor executor blocked, cancellation delayed |

---

## Recommendations

### Immediate (CRITICAL)
1. Fix fire-and-forget producer Tasks in `MetalMosaicGenerator` (lines 212, 415) — use `continuation.onTermination`
2. Remove `@unchecked Sendable` from `MetalImageProcessor` — protect metrics with `Mutex`
3. Add `continuation.onTermination` to `extractFramesStream` in `ThumbnailProcessor`
4. Align `PreviewGenerationLogic.generate` isolation with `generateComposition` (`@MainActor`)

### Short-Term (HIGH)
5. Replace `MosaicGenerator.internalGenerator: Any?` with `any MosaicGeneratorProtocol`
6. Make `LayoutProcessor` thread-safe (actor or `Mutex`)
7. Add comment to `nonisolated(unsafe)` at line 1115 explaining isolation contract
8. Remove `@preconcurrency import CoreImage` (CGImage is Sendable)

### Long-Term
9. Add `@concurrent` to CPU-intensive image processing methods
10. Migrate `NSLock` in `CancellationToken`/`ExportProgressTracker` to `Mutex`
11. Enable `-strict-concurrency=complete` in Package.swift and resolve all warnings
