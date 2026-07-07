# Preview Exporting Guide

A comprehensive guide on managing concurrent video exports, handling background states, and preventing stalls when using MosaicKit's preview generation.

## Overview

Generating preview videos in MosaicKit relies heavily on `AVAssetExportSession`, `AVVideoCompositionCoreAnimationTool`, and Apple's underlying hardware video encoders (VideoToolbox). While Apple Silicon and modern iOS devices are highly capable, video encoding is a heavily constrained system resource. 

Developers using `MosaicKit` frequently encounter stalls, timeouts, or `PreviewError.exportStalled` when two primary limits are exceeded: **Hardware Encoder Concurrency Limits** and **Background/App Nap Suspensions**.

This guide explains these limits and provides best practices for launching and managing preview generation.

## Hardware Encoder Limits

Apple's hardware encoders (H.264 / HEVC) are finite, shared system resources. 

* **iOS Devices**: Typically support a maximum of **2 to 4 concurrent hardware-accelerated encoding sessions** depending on the chip (A-series) and device thermal state.
* **macOS (Apple Silicon)**: Generally support more concurrent streams (e.g., up to 8 on M1/M2/M3 depending on the tier), but the limit is still strictly bounded by the Media Engine.

### Symptoms of Exceeding Limits
If you launch too many preview generations simultaneously:
1. `AVAssetExportSession` will silently queue tasks, delaying progress.
2. If memory pressure or thermal limits are hit, the system will aggressively kill or stall the exports.
3. MosaicKit's stall detector will time out the export and throw `PreviewError.exportStalled`.

### Best Practices for Concurrency
**Do not launch parallel exports for an unbounded number of videos.**
Instead, use a serial queue or limit concurrency to `1` or `2` active preview generations at a time using Swift Concurrency structures (e.g., `TaskGroup` with a bounded number of concurrent tasks, or a custom actor).

```swift
// Example of serial execution
for video in videos {
    do {
        let url = try await generator.generatePreview(for: video, config: config)
        print("Exported: \(url)")
    } catch {
        print("Failed to export \(video.title): \(error)")
    }
}
```

## Background States and Window Occlusion

The most common cause of `PreviewError.exportStalled` is the host app entering the background (iOS) or being hidden/occluded (macOS).

### iOS Background Suspension
iOS prioritizes the foreground app and battery life. When your app enters the background:
1. The system immediately suspends standard processing.
2. Hardware encoder access is immediately revoked for background apps.
3. MosaicKit requests a brief background task (`beginBackgroundTask`), but this only grants roughly **30 seconds**. If the export takes longer than 30 seconds, the system suspends the app, causing `AVAssetExportSession` to fail with `operationInterrupted` or stall completely.

### macOS App Nap and Core Animation
macOS aggressively reduces CPU and GPU usage for apps whose windows are hidden, minimized, or completely occluded by other windows (App Nap).
* `AVVideoCompositionCoreAnimationTool`, which MosaicKit uses for compositing transitions, **relies on Core Animation**. If the window is hidden, Core Animation stops rendering to save power.
* While MosaicKit automatically requests `.userInitiated` `ProcessInfo` activity tokens, this does **not** override window occlusion suspensions for Core Animation. The export will stall.

### Best Practices for Background Resiliency

To prevent export timeouts and stalls, you must architect your app to gracefully handle backgrounding:

#### 1. Only Export in the Foreground (Recommended)
Pause or cancel exports when your app goes into the background, and resume them when returning to the foreground.
* **iOS**: Observe `UIApplication.didEnterBackgroundNotification` and cancel your `Task` running the export. Resume when receiving `UIApplication.willEnterForegroundNotification`.
* **macOS**: Observe `NSApplication.didResignActiveNotification` or `NSWindow.didChangeOcclusionStateNotification`.

#### 2. Prevent Display Sleep
If your app is exporting a massive batch of previews overnight, ensure the screen remains awake and the app remains in the foreground.
* **iOS**: `UIApplication.shared.isIdleTimerDisabled = true`
* **macOS**: Use `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Batch Exporting")` at the app level.

#### 3. iOS BGProcessingTask (Advanced)
If you absolutely must export in the background on iOS, you cannot use standard tasks. You must defer the work to a `BGProcessingTask` (via the `BackgroundTasks` framework). Note that the system only executes these tasks when the device is idle, plugged in to power, and connected to Wi-Fi.

## Handling Stalls in Code

MosaicKit features a built-in stall detector. If progress is frozen for 60 seconds (iOS) or 120 seconds (macOS), it proactively cancels the session and throws `PreviewError.exportStalled(elapsedSeconds:)`.

You should catch this specific error and handle it gracefully by offering the user a "Resume" button or queuing it for a retry when the app becomes active again:

```swift
do {
    let outputURL = try await generator.generatePreview(for: video, config: config)
} catch PreviewError.exportStalled(let seconds) {
    print("Export stalled after \(seconds)s of inactivity. (Likely backgrounded)")
    // Queue for retry when foregrounded
} catch {
    print("Other export error: \(error)")
}
```

## Cancelling Exports

There are two equivalent ways to cancel preview work; both stop the underlying
export session (native `AVAssetExportSession`, `SJSAssetExportSession`, and the
external `ffmpeg` process all observe cancellation):

1. **Cancel the Swift `Task`** that awaits the generator or coordinator call.
   Task cancellation propagates into the export pipeline, including
   foreground waits and stall-retry sleeps.
2. **Call the coordinator's cancel API**:

```swift
// Cancel one video. During a batch, only this video is affected:
// it finishes as a `.failure` result and the rest of the batch continues.
await coordinator.cancelGeneration(for: video)

// Cancel everything. In-flight exports are torn down, videos still queued
// in a running batch are never started, and the awaited batch call
// (`generatePreviewsForBatch` / `generatePreviewCompositionsForBatch`)
// throws `CancellationError`.
await coordinator.cancelAllGenerations()
```

Cancelled videos are reported to progress handlers with the `.cancelled`
status (not `.failed`), and single-video calls throw `PreviewError.cancelled`.

Catch the batch-wide cancellation where you await the batch:

```swift
do {
    let results = try await coordinator.generatePreviewsForBatch(videos: videos, config: config)
    // all videos processed (some may still be individual failures)
} catch is CancellationError {
    print("Batch was cancelled — remaining videos were not started")
}
```
