# Generation reliability and performance specification

Status: implementation specification. Branch: `codex/generation-reliability`.

## Scope

Implement review stages 1–5: correctness, public Swift job APIs, individual/batch controls, bounded mosaic generation, and preview export improvements. Stage 6 is deferred: no CI workflow overhaul, benchmark infrastructure, broad documentation cleanup, or unrelated existing-test expectation changes. Focused regression tests and a DocC article for new public APIs remain required implementation validation.

Existing async generation APIs remain source compatible. Minimum deployment targets remain OS 26 and Swift tools 6.2. No new package dependencies. Existing uncommitted changes in the original checkout are excluded from this worktree.

## 1. Correctness invariants

- Source identity is distinct from job and attempt identity. Concurrent configurations for the same source must not share outputs, callbacks, or cancellation ownership accidentally. Cleanup only removes state owned by its attempt.
- Cancellation is cooperative and observable. Extraction termination on cancellation throws; no partial render is published as successful. Check cancellation before expensive stages, during bounded work, and immediately before publishing output. Await owned tasks/resources before acknowledging quiescence.
- Every encoder writes to an attempt-owned sibling staging file. Finalize and validate it, check cancellation, and publish atomically. Failure/cancellation removes staging files, never an earlier valid output. No-overwrite conflicts cannot silently replace existing files.
- Reject nonfinite/nonpositive durations, dimensions, density factors, invalid quality/FPS, and invalid concurrency before conversion/allocation. Nonthrowing legacy calculation helpers must never trap for invalid arguments.
- GPU failures propagate from every submitted command buffer. Missing extracted frames have an explicit strict/best-effort policy and never silently masquerade as complete success.
- Preview segment insertion is transactional across audio/video or fails explicitly. SJS receives the intended audio mix. Preserve fractional timing.
- A mosaic-plus-animation request evaluates both artifacts. Retrying a missing animation preserves an existing mosaic.

## 2. Public API and planning

Add lightweight `VideoSource`, explicit throwing inspection, immutable `GenerationRequest` and `GenerationPlan`, typed `JobID`/`AttemptID`/`BatchID`, `JobHandle`/`BatchHandle`, typed outcomes/artifacts/capabilities/metrics, and one processing-service actor.

`VideoSource` construction does no I/O. Inspection loads canonical metadata once and preserves supplied metadata/custom values. Security-scoped access must be balanced and ordinary accessible file URLs supported. Existing async `VideoInput` initializers remain adapters. Throwing discovery reports errors and observes cancellation with bounded metadata loading.

Plans freeze request configuration, output paths, source fingerprint, capabilities, and estimated resource cost. Output identity includes relevant configuration and source identity; retry reuses a frozen plan rather than re-resolving clock-dependent paths. Public validation rejects unsupported backend/overlay/encoder combinations early.

WebP registration is synchronized; explicit encoder injection is supported where practical. Metrics cross actor boundaries as Sendable values. Legacy result and metric APIs remain available.

## 3. Processing controls

The service owns one admission budget across singles and all batches. A submitted job has stable identity; each retry has a new attempt. State transitions are queued, running, pausing, paused, retryScheduled, cancelling, succeeded, failed, cancelled. Exactly one terminal outcome per attempt. Old-attempt events are ignored.

Job handles expose snapshot, outcome waiting, observation, cancel, pause, resume, and retry. Batch handles expose stable ordered snapshots and controls over all or selected job IDs. Batch cancellation preserves completed, failed, cancelled and unstarted records. Observation termination does not cancel work.

Pause policy is explicit: queued admission pause, allow active work to finish, or cancel/checkpoint an active stage for later restart. Acknowledged pause means no further admission for that selection. Never promise byte-level encoder continuation on OS 26. Active restart preserves committed artifacts and immutable plan data. Retry selects failed/cancelled/unstarted jobs or requested artifacts and uses bounded attempts/backoff for eligible transient failures. Cancellation interrupts retry delay.

Provide optional versioned file-backed checkpoint/ledger persistence with source/configuration validation and explicit retention/cleanup. Durable manifests contain values, never AVFoundation/Metal objects or callbacks. OS 27 native resumption remains an availability-gated future enhancement; do not require beta APIs.

## 4. Mosaic pipeline

Bound both decoded-frame buffering and overlay work. Do not replace unbounded streams with dropping buffers. Use a suspending producer/consumer or pull-based sequence. Sample a bounded set for dominant colors, composite incrementally, bound GPU submissions, and release frames after GPU completion.

Use actual cell requirements for decode sizing with an explicit quality scale. Reuse canonical metadata and compatible extraction work where feasible; avoid unnecessary CPU rasterization/readback copies without weakening buffer lifetime safety. Make layout caching keyed by all inputs and bounded. Consolidate duplicated file/image pipeline logic where feasible.

Performance experiments (zero-copy decoder paths, direct FFmpeg filters, broad benchmark harnesses) must not be represented as measured wins. Implement safe bounded-work improvements now; keep unproven backend replacements explicit follow-ups.

## 5. Preview pipeline

Validate and resolve timing, geometry, backend, audio, overlays and output once. Fix native preset cap mappings and SJS audio-mix forwarding. Avoid unnecessary rendering composition when edits/transforms permit, while preserving orientation and audio timing.

Retain/reuse validated intermediate stages for checkpoint retry where supported, with bounded storage and cleanup. Current FFmpeg two-stage encoding remains a valid fallback; direct-source lowering requires fidelity/performance evidence before replacing it.

Own FFmpeg lifecycle with cancellation before launch, bounded graceful termination and force termination fallback, exactly-once completion and bounded error diagnostics. Emit ordered progress and release subscriptions. macOS focus changes must not gate export admission. Host lifecycle/audio-session policies are explicit; remove unconditional per-job focus polling and unsolicited shared audio-session mutation.

## Work packets and ownership

| Packet | Owner | Files | Dependencies | Verification |
|---|---|---|---|---|
| A | Mosaic worker | MetalMosaicGenerator, MetalImageProcessor, ThumbnailProcessor, LayoutProcessor, AnimatedGifGenerator; new mosaic regression tests | shared OutputTransaction helper | Build + cancellation/output/stream tests |
| B | Preview worker | Processing/Preview/*; new preview regression tests | shared OutputTransaction helper | Build + composition/lifecycle/process tests |
| C | Input/API worker | Models/*, VideoInputScanner, WebPSupport, SourcesWebP; new model regression tests | none | Build + validation/input/capability tests |
| D | Root | new Processing/Jobs/*, OutputTransaction, MosaicGeneratorCoordinator, protocol additions, integration tests and new DocC article | A/B/C APIs integrated after wave 1 | Build + deterministic job/batch tests + combined regression suite |

Workers must not edit outside ownership or run git mutations. Root integrates and validates sequentially. Preserve legacy symbols; deprecated adapters are preferable to source breaks. Existing failing unrelated tests are recorded, not rewritten merely to make the suite green.

## Acceptance checks

1. Same input with different requests has independent attempt ownership and cancellation.
2. Cancel during extraction/export/precommit never publishes incomplete output or destroys a valid old artifact.
3. Invalid numeric input and negative concurrency fail safely.
4. Global service admission never exceeds its fixed limit across simultaneous batches and singles.
5. Paused queued jobs do not start; active restart waits for quiescence; cancelled batches retain all result records.
6. Selected retries use new attempts and preserve successful artifacts; durable recovery rejects changed sources/configurations.
7. Streaming buffers/workers remain bounded without dropping required frames, and GPU errors fail generation.
8. Preview backends honor supported audio/geometry/timing policies; unsupported combinations fail validation.
9. Swift build and focused regression tests pass; full-suite pre-existing failures and untested hardware/backend cases are reported accurately.
