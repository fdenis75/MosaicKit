# Test Quality Audit — MosaicKit (2026-05-10)

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| HIGH | 5 |
| MEDIUM | 4 |
| LOW | 3 |

**Framework**: 100% Swift Testing (no XCTest) — migration complete.
**Module coverage**: ~11/27 production types meaningfully tested (41%).

---

## Coverage Shape Map

| Area | Status |
|------|--------|
| Error types (all 4 enums) | ✅ Comprehensive |
| Layout calculation (`LayoutProcessor`) | ✅ |
| Overlay processing | ✅ |
| Thumbnail processing | ✅ |
| MosaicConfiguration Codable | ✅ |
| Animated image generation | ⚠️ Broken — hard-coded personal path |
| Coordinator integration | ⚠️ Partial — guarded by env vars |
| `PreviewVideoGenerator` | ❌ 1 trivial test only |
| `CoreGraphicsMosaicGenerator` | ❌ Zero tests |
| `MetalImageProcessor` / `CoreGraphicsImageProcessor` | ❌ Zero tests |
| `VideoMetadataExtractor` | ❌ Zero tests |
| `MosaicGeneratorFactory` / public `MosaicKit` entry point | ❌ Zero tests |
| `PreviewGeneratorCoordinator` | ❌ Zero tests |

---

## CRITICAL — Hard-Coded Personal Path Breaks All Animated Image CI Tests

**File**: `Tests/MosaicKitTests/AnimatedGifGeneratorTests.swift:379`

The `embeddedVideoURL` computed property has its `Bundle.module.url` implementation commented out and replaced with a literal path to a file on a personal external hard drive:

```swift
let url = URL(fileURLWithPath: "/Volumes/Ext-6TB-2/Studios/Wake Up n Fuck/Solo/...")
```

10 of 14 test functions in `AnimatedGifGeneratorTests` use this. All fail on any machine other than the developer's. The bundled test asset (`test_video.mp4`) already exists and is ready to use.

**Fix**:
```swift
private var embeddedVideoURL: URL {
    get throws {
        guard let url = Bundle.module.url(forResource: "test_video", withExtension: "mp4") else {
            throw TestError.embeddedAssetMissing
        }
        return url
    }
}
```

---

## CRITICAL — Commented-Out `defer` Leaves Test Output Files on Disk Permanently

**File**: `Tests/MosaicKitTests/AnimatedGifGeneratorTests.swift:196, 329, 354`

Three integration tests have `defer { try? FileManager.default.removeItem(at: outputDir) }` commented out. `createAllModes` creates `outputDir` in `/tmp` but never cleans it up at all. Output is also written to `videoURL.deletingLastPathComponent()` — the external drive path.

**Fix**: Restore all three commented `defer` blocks. Add `defer` to `createAllModes`. Use `outputDir` (not `videoURL.deletingLastPathComponent()`) as the output location.

---

## HIGH — PreviewVideoGenerator Has Only 1 Trivial Test

**File**: `Tests/MosaicKitTests/PreviewVideoGeneratorTests.swift`

The entire `PreviewVideoGenerator` actor — the main preview generation pipeline including AVFoundation composition, export sessions, audio processing, and cancellation — has exactly one test: `extractTimestampFormatting`, which tests a static string formatter with three values. `PreviewGeneratorCoordinator` is completely untested.

**Fix**: Add integration tests using the embedded asset for:
- Happy-path `PreviewVideoGenerator.generate`
- Cancellation (`cancel(for:)` from a concurrent task)
- `PreviewError.insufficientVideoDuration` when video is too short
- `PreviewGeneratorCoordinator` single-video and batch paths

Use `@Test(.timeLimit(.minutes(2)))` to prevent hangs.

---

## HIGH — CoreGraphicsMosaicGenerator and Image Processors Have Zero Tests

`CoreGraphicsMosaicGenerator`, `MetalImageProcessor`, and `CoreGraphicsImageProcessor` have no dedicated tests. The coordinator tests only exercise `MetalMosaicGenerator` (macOS Metal path). The iOS rendering engine (`CoreGraphicsMosaicGenerator`) could be entirely broken with all tests passing.

**Fix**: Add `CoreGraphicsImageProcessorTests` with synthetic `CGImage` inputs (no real video needed). Test `CoreGraphicsMosaicGenerator` directly. Gate Metal-specific tests with `#if os(macOS)`.

---

## HIGH — MosaicGeneratorCoordinatorTests Has Hard-Coded Developer Machine Path

**File**: `Tests/MosaicKitTests/MosaicGeneratorCoordinatorTests.swift:6`

```swift
private static let defaultMediaFolderPath = "/Users/francois/Downloads/testvidsnodelete"
```

When `MOSAICKIT_TEST_VIDEOS_DIR` is not set, folder-based tests attempt to access this path. Although guarded by `MOSAICKIT_SUITE_MODE`, contributors running tests without env vars see confusing failures.

**Fix**: Change default to a safe fallback (e.g., `/tmp/mosaickit-test-videos`) and document required env vars in a comment.

---

## HIGH — VideoMetadataExtractor Has No Tests

`VideoMetadataExtractor` (actor, `async throws`) is used in every generation pipeline but has no direct unit tests. `VideoError.metadataExtractionFailed` and `VideoError.videoTrackNotFound` can never be triggered by tests.

**Fix**: Add `VideoMetadataExtractorTests` using the bundled asset. Verify `extractMetadataValues(from:)` returns correct duration, resolution, codec. Add a test that passes a non-video file and expects the appropriate `VideoError`.

---

## HIGH (Compound) — Untested `PreviewVideoGenerator` + Complex Async/Cancellation Infrastructure

`PreviewVideoGenerator` uses `CancellationToken` (`@unchecked Sendable` + `NSLock`) and `ExportProgressTracker` (`@unchecked Sendable` + `NSLock`). None of this concurrency infrastructure is tested. Combined with only 1 trivial test covering the whole subsystem, any data race, deadlock, or cancellation timing issue is invisible.

**Cross-auditor note**: Overlaps with concurrency audit — `@unchecked Sendable` bypasses Swift 6 checking on these types.

---

## MEDIUM — `createAllModes` Test Has Typo and Wrong Output Directory

**File**: `Tests/MosaicKitTests/AnimatedGifGeneratorTests.swift:284`

`@Test("create all versionsq")` — stray `q` in the name. The test creates `outputDir` in `/tmp` but writes output to `videoURL.deletingLastPathComponent()` (the external drive). The `outputDir` is created but never used and never cleaned up.

**Fix**: Fix the name typo, use `outputDir` as output, add `defer` cleanup.

---

## MEDIUM — MosaicGeneratorFactory and Public MosaicKit Entry Point Untested

`MosaicGeneratorFactory` (engine selection) and `MosaicKit.swift` (public `MosaicGenerator` with `.auto`, `.preferMetal`, `.preferCoreGraphics`) have no tests. Any regression in engine selection is invisible.

**Fix**: Add tests for `MosaicGenerator(preference: .auto)` and `MosaicGenerator(preference: .preferCoreGraphics)`. Verify `MosaicGeneratorFactory.make()` returns the expected type per platform.

---

## MEDIUM — VideoError API Bugs Not Caught by Tests

Two silent API bugs:
1. `VideoError.associatedURL` returns `nil` for `.accessDenied(URL)` and `.invalidFormat(URL)` even though both carry a URL as an associated value
2. `VideoError.underlyingError` returns `nil` for `.frameExtractionFailed(URL, Error)` even though it wraps an `Error`

Neither is covered by the existing `ErrorTypesTests`, giving false confidence.

**Fix**: Add `.accessDenied` and `.invalidFormat` to the URL-returning arm of `associatedURL`. Add `.frameExtractionFailed` to the non-nil arm of `underlyingError`. Add the corresponding test assertions.

---

## LOW — `CombinationTests` Claims 200 Combinations But Runs 10

**File**: `Tests/MosaicKitTests/CombinationTests.swift:281-348`

Groups G01–G10 and G13 are entirely commented out in `makeAll()`. The docstring claims 200 total configurations. Only ~10 run (G11 only). The assertion `succeeded > 0` is trivially weak — one success passes the test.

**Fix**: Restore or delete the commented groups and update the docstring. Strengthen assertion to `succeeded == total`.

---

## LOW — `ProgressStore` Uses `@unchecked Sendable + NSLock` Instead of Actor

**File**: `Tests/MosaicKitTests/MosaicGeneratorCoordinatorTests.swift:335-350`

Test helper `ProgressStore` is `@unchecked Sendable` with `NSLock`. Swift Testing + Swift 6 actors are the idiomatic choice for concurrent test helpers.

**Fix**: Convert to an `actor`.

---

## LOW — No `.timeLimit` Traits on Long-Running Integration Tests

Integration tests in `AnimatedGifGeneratorTests` and `MosaicGeneratorCoordinatorTests` that invoke the full generation pipeline have no timeout guard. A stalled Metal pipeline or hanging asset loader will block the CI runner indefinitely.

**Fix**: Add `@Test(.timeLimit(.minutes(3)))` to all pipeline integration tests.

---

## Quick Wins (3 lines each)

1. Restore `Bundle.module.url` in `embeddedVideoURL` — fixes 10 broken CI tests immediately
2. Restore 3 commented `defer` blocks (lines 196, 329, 354) — stops disk accumulation
3. Fix `VideoError.associatedURL` and `underlyingError` — 2 production lines + 2 test assertions
