# Background Processing on iOS

A how-to guide for wrapping MosaicKit mosaic and preview generation in `BGContinuedProcessingTask`
so long-running jobs can survive the host app moving to the background.

## Overview

iOS 26 introduces `BGContinuedProcessingTask` (see Apple's ["Performing long-running tasks on iOS
and iPadOS"](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados))
as the supported way to keep a user-initiated, long-running job alive — with system UI showing
progress — after the app backgrounds. **MosaicKit does not import `BackgroundTasks` and does not
register, submit, or manage any `BGContinuedProcessingTask` itself.** Task identifiers live in your
app's `Info.plist`, `BGTaskScheduler` registration happens at your app's launch, and the
background-task progress UI is owned by the system on your app's behalf — none of that is
MosaicKit's concern or a dependency it should take on.

What MosaicKit *does* do, and has done since its cancellation model was designed, is make itself a
good citizen inside whatever scope wraps it: every generation call is cooperative with Swift `Task`
cancellation and unwinds cleanly when cancelled, and every progress handler reports a plain
`Double` fraction (0.0–1.0) or discrete status enum that maps directly onto a
`BGContinuedProcessingTask`'s progress reporting with no translation layer. This article shows the
app-side integration pattern; treat it as a recipe for your app target, not as API MosaicKit
exposes.

## Registering the Task

Register a `BGContinuedProcessingTaskRequest` identifier with `BGTaskScheduler` at app launch,
matching an entry under `BGTaskSchedulerPermittedIdentifiers` in your `Info.plist`:

```swift
// Info.plist
// <key>BGTaskSchedulerPermittedIdentifiers</key>
// <array>
//     <string>com.example.myapp.mosaic-generation</string>
// </array>

import BackgroundTasks

let mosaicTaskIdentifier = "com.example.myapp.mosaic-generation"

func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: mosaicTaskIdentifier,
        using: nil
    ) { task in
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        handleMosaicBackgroundTask(task)
    }
}
```

Call `registerBackgroundTasks()` before `application(_:didFinishLaunchingWithOptions:)` returns (or
in your `App`'s `init` on SwiftUI) — registration must happen unconditionally at launch, whether or
not a task is submitted this session.

## Wrapping Mosaic Generation

The app submits the `BGContinuedProcessingTaskRequest` when the user starts a batch, then runs
`MetalMosaicGenerator` or `MosaicGeneratorCoordinator` inside the handler, forwarding MosaicKit's
progress fraction straight into the task's progress reporting:

```swift
import BackgroundTasks
import MosaicKit

@MainActor
func startMosaicBatch(videos: [VideoInput], config: MosaicConfiguration) throws {
    let request = BGContinuedProcessingTaskRequest(
        identifier: mosaicTaskIdentifier,
        title: "Generating Mosaics",
        subtitle: "\(videos.count) videos"
    )
    request.strategy = .queue
    try BGTaskScheduler.shared.submit(request)
}

func handleMosaicBackgroundTask(_ task: BGContinuedProcessingTask) {
    let videos: [VideoInput] = pendingVideos
    let config: MosaicConfiguration = pendingConfig

    let work = Task {
        do {
            let generator = try MetalMosaicGenerator()
            let coordinator = MosaicGeneratorCoordinator(mosaicGenerator: generator)
            let results = try await coordinator.generateMosaicsforbatch(
                videos: videos,
                config: config
            ) { progress in
                // MosaicGenerationProgress.progress is already 0.0...1.0 —
                // no conversion needed before handing it to the task.
                task.progress.completedUnitCount = Int64(progress.progress * 1000)
            }
            let failures = results.filter { !$0.isSuccess }
            task.setTaskCompleted(success: failures.isEmpty)
        } catch is CancellationError {
            // Expiration handler below already cancelled us; report .cancelled,
            // not a failure.
            task.setTaskCompleted(success: false)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    task.expirationHandler = {
        work.cancel()
    }
    task.progress.totalUnitCount = 1000
}
```

`task.progress` is a standard `Progress`, so `completedUnitCount` / `totalUnitCount` is all you
need — `MosaicGenerationProgress.progress` (a `Double` in `0.0...1.0`) scales onto it directly.

## Wrapping Preview Generation

The same pattern applies to `PreviewVideoGenerator` / `PreviewGeneratorCoordinator`, using
`PreviewGenerationProgress.progress`:

```swift
func handlePreviewBackgroundTask(_ task: BGContinuedProcessingTask) {
    let coordinator = PreviewGeneratorCoordinator()
    let video: VideoInput = pendingVideo
    let config: PreviewConfiguration = pendingPreviewConfig

    let work = Task {
        do {
            let outputURL = try await coordinator.generatePreview(
                for: video,
                config: config
            ) { progress in
                task.progress.completedUnitCount = Int64(progress.progress * 1000)
            }
            task.setTaskCompleted(success: true)
            print("Preview saved to \(outputURL)")
        } catch is CancellationError {
            task.setTaskCompleted(success: false)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    task.expirationHandler = {
        work.cancel()
    }
    task.progress.totalUnitCount = 1000
}
```

> **Set `PreviewConfiguration.enableAppLifecycleMonitor = false`** whenever the export runs inside a
> `BGContinuedProcessingTask`. Its default (`true`) wires `PreviewVideoGenerator` to
> `AppLifecycleMonitor.waitUntilForeground()`, which *suspends the export the moment
> `UIApplication.didEnterBackgroundNotification` fires* and only resumes on
> `willEnterForegroundNotification` (or cancellation). That's the right behavior for an export
> started with no background entitlement at all, but it directly defeats the purpose of
> `BGContinuedProcessingTask`: your app backgrounds immediately after the user leaves it, the
> monitor stalls the export waiting for a foreground return that may not come until the background
> task has already expired, and none of the execution time the system granted you gets used.
> `enableExportRetry` can stay at its default (`true`) — the stall-retry logic there is unrelated to
> the foreground-wait gate and still helps recover from transient hardware-encoder throttling. Only
> revert `enableAppLifecycleMonitor` to `true` if you are *not* wrapping the call in a background
> task and want the old foreground-only behavior; for genuinely headless contexts (daemons, XPC,
> CLI) set both `false` per the guidance in the package's `CLAUDE.md`.

## Handling Expiration and Cancellation

`BGContinuedProcessingTask.expirationHandler` is your only signal that the system is revoking the
task. Wire it to cancel the Swift `Task` that awaits the MosaicKit call — do nothing else:

```swift
task.expirationHandler = {
    work.cancel()
}
```

From there, MosaicKit's existing cancellation model takes over and unwinds cleanly:

- Cancelling the awaiting `Task` propagates into `MetalMosaicGenerator`'s and
  `PreviewVideoGenerator`'s tracked internal tasks (`generationTasks` / equivalent dictionaries),
  each of which is awaited under `withTaskCancellationHandler` so cancellation reaches work that
  unstructured `Task`s would not otherwise inherit.
- `PreviewVideoGenerator` bridges the cancellation into its `CancellationToken`, which the export
  watchdog and phase checks poll — so an in-flight `AVAssetExportSession` / `SJSAssetExportSession`
  / `ffmpeg` process is torn down promptly rather than left running after expiration.
- `MosaicGeneratorCoordinator` / `PreviewGeneratorCoordinator` batch loops check a `batchEpoch`
  counter bumped by `cancelAllGenerations()`, so a cancelled batch stops dequeuing queued videos
  instead of starting new work after the task has already expired.
- Every long-running loop (frame extraction, animated-image encoding, per-segment composition)
  calls `Task.checkCancellation()` per iteration, so cancellation is observed promptly even mid-loop.

The net effect: your `catch is CancellationError` branch is reached quickly and reliably, and
progress handlers report `.cancelled` (mosaic) or `.cancelled(for:)` (preview) rather than
`.failed` — call `task.setTaskCompleted(success: false)` in that branch, since a cancelled task is
not a completed one, but avoid treating it as an app-level error worth surfacing to the user beyond
"paused — resume when you reopen the app."

## Platform Notes

`BGContinuedProcessingTask` is **iOS and iPadOS 26+ only**. On macOS and macCatalyst there is no
equivalent requirement: Mac apps are not subject to the same background-suspension model, so a
plain `await` on `MetalMosaicGenerator` or `PreviewVideoGenerator` from a normal `Task` is
sufficient — wrapping macOS calls in `BackgroundTasks` API is neither necessary nor supported
(`BGContinuedProcessingTask` itself is unavailable there).

Even with a `BGContinuedProcessingTask` granted, Metal GPU access can still be constrained while
the app is backgrounded — the OS may throttle or briefly suspend GPU scheduling for a backgrounded
process regardless of the background task's grant. Treat GPU-related failures surfaced by
MosaicKit (for example `MosaicError.metalNotSupported` or `MosaicError.processingFailed`
appearing only while backgrounded) as **retryable once the app returns to the foreground**, not as
fatal errors — queue the video for retry rather than surfacing a permanent failure to the user.

## Checklist

- [ ] `BGTaskSchedulerPermittedIdentifiers` in `Info.plist` includes your mosaic/preview task
      identifier, and it's registered with `BGTaskScheduler` unconditionally at launch.
- [ ] `BGContinuedProcessingTaskRequest` is submitted only when the user actually starts a batch,
      not speculatively.
- [ ] `task.expirationHandler` cancels the Swift `Task` running the MosaicKit call — nothing more;
      MosaicKit's own cancellation model handles the teardown.
- [ ] Progress handler fractions (`MosaicGenerationProgress.progress` /
      `PreviewGenerationProgress.progress`) are forwarded directly into `task.progress`, with
      `totalUnitCount` set once up front.
- [ ] `CancellationError` is handled as `.cancelled`, calling `task.setTaskCompleted(success: false)`
      without treating it as a user-facing failure.
- [ ] GPU-related failures encountered while backgrounded are queued for retry in the foreground
      rather than surfaced as fatal.
- [ ] macOS/macCatalyst code paths skip `BackgroundTasks` entirely and call MosaicKit directly.

---

**This document describes a pattern for app code, not something implemented inside MosaicKit
itself.** `BackgroundTasks` is an app-level framework — MosaicKit has no dependency on it and no
`BGContinuedProcessingTask`-aware API surface. Everything above lives in your app target.
