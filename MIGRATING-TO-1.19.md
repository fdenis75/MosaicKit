# Migrating to MosaicKit 1.19.0

This guide is for apps that already use MosaicKit 1.18.x. 1.19.0 adds an opt-in way to read
transport streams that AVFoundation can't (HEVC, AV1 or MPEG-4 Part 2 in `.ts`) on macOS, by
remuxing them with ffmpeg (I-38). Nothing changes unless you turn it on.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| doesn't call `TransportStreamRemuxer.enable` | — | None (1.18 behavior: these sources fail with `VideoError.unsupportedCodec`) |
| runs on macOS with an ffmpeg binary and wants HEVC `.ts` sources | [2.1](#21-transportstreamremuxer) | Opt-in |
| runs on iOS or Mac Catalyst | — | None (`enable` throws; `TransportStreamRemuxer.isSupported` is `false`) |

## 2. Changes

### 2.1 `TransportStreamRemuxer`

```swift
#if os(macOS)
try TransportStreamRemuxer.enable(
    ffmpegBinaryPath: "/opt/homebrew/bin/ffmpeg",
    cacheDirectory: nil,              // default: <temp>/MosaicKitRemux
    maximumCacheBytes: TransportStreamRemuxer.defaultMaximumCacheBytes  // 20 GB
)
#endif
```

- **Process-wide.** Call it once at startup. It isn't part of `MosaicConfiguration`, because
  inspection (`VideoInput(from:)`) has no configuration. `disable()` turns it off, `clearCache()`
  deletes the cached files and `isEnabled` reports the state.
- **When it remuxes.** Only for a transport stream (sniffed, or named `.ts`/`.m2ts`/`.mts`) that
  AVFoundation can't read video from. H.264 and MPEG-2 TS are still read directly.
- **How.** It runs `ffmpeg -c copy`: no re-encode, the first video and first audio stream, other
  streams dropped, written as MP4 with the `hvc1` tag that AVFoundation needs for HEVC. Every
  reader of the source then opens the cached MP4: inspection, mosaics, animations, previews and
  thumbnails. Output names, `VideoInput` metadata and the file size still come from the source URL.
- **Remote sources.** ffmpeg downloads the whole file, once (a 211 MB link costs 211 MB). The MP4
  is kept in the cache, keyed by the source URL (plus size and modification date for a local file),
  and reused by later calls and later runs. A refreshed signed URL is a new key. `reduceSourceReads` doesn't apply to remuxed sources.
- **Cache.** When the cache grows past `maximumCacheBytes`, the least recently used files are
  deleted. Free space is checked against the source size plus 500 MB before a remux.
- **Errors.**
  - `enable` throws `MosaicError.invalidConfiguration` for a path that isn't executable, and on
    iOS/Catalyst.
  - A failed remux throws `VideoError.processingFailed(url, underlying)`; the underlying error
    carries ffmpeg's output.
  - A cancelled reader throws `CancellationError`. Concurrent readers of one source share a single
    ffmpeg run, which stops only when every one of them has cancelled.
- **ffmpeg must stay reachable.** The `.ffmpeg` preview mode already requires a binary path;
  sandboxed apps need the same entitlement or bundling.

## 3. Tessera checklist

- Bump MosaicKit to `1.19.0` in `project.yml`.
- MPGenCore/CLI (macOS): when an ffmpeg path is configured, call
  `TransportStreamRemuxer.enable(ffmpegBinaryPath:)` at startup, wrapped in `#if os(macOS)`. The
  App Store build, which has ffmpeg off, doesn't call it and keeps the 1.18 error.
- Optionally expose `clearCache()` or a custom `cacheDirectory` in settings.
- iOS: nothing to do.
