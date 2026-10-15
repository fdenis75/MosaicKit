# Migrating to MosaicKit 1.10.0

This guide is for apps that already use MosaicKit 1.9.x. 1.10.0 removes and changes nothing in the
public API, so **no code change is required**. It has one new function and one visible change in
mosaic headers. Coming from 1.8.x or earlier? Read [MIGRATING-TO-1.9.md](MIGRATING-TO-1.9.md) and
[MIGRATING-TO-1.8.md](MIGRATING-TO-1.8.md) first.

Checked against the code at tags `1.9.1` and `1.10.0`: the public API surface differs only by the
additions in section 1.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| lists `.colorPalette(swatchCount:)` in a mosaic header (`HeaderConfig.fields`) | [2.1](#21-colorpalette-header-swatches-now-render) | Header looks different (swatches appear) |
| scans folders with `discoverVideos` and wants to survive undecodable files | [3](#3-new-discovervideosreportingfailures) | Optional new API |

Everything else is unchanged: defaults, the configuration format, output file names and locations,
errors, cancellation, and throughput (checked with an A/B/A benchmark).

## 2. Behavior changes

### 2.1 `.colorPalette` header swatches now render

`MetadataField.colorPalette(swatchCount:)` was accepted and round-tripped through `Codable`, but
drew nothing, because the generator never gave the header any colors (I-10). It now draws that many
color circles in the header's right corner, at most 32.

- **What the swatches are:** the average color of frames spread evenly over the middle 90 % of the
  video, sampled before the header is built. They are frame averages, not a clustering of dominant
  colors.
- **Cost:** a few small frames are decoded, and only when the header has the field. Configurations
  without it are unaffected.
- **Layout:** header height and mosaic size do not change; the swatches are drawn inside the header.
- **You are affected if** a header you build or load lists `.colorPalette`. Mosaics generated from
  it now show swatches. Mosaics already on disk are not touched; regenerate them with
  `overwrite = true` to get the swatches.
- **To keep the old look:** remove `.colorPalette` from `HeaderConfig.fields`.

## 3. New: `discoverVideosReportingFailures`

`discoverVideos(in:recursive:metadataConcurrency:)` throws as soon as one file can't be inspected
(an `.mkv` AVFoundation can't read, a corrupt file, an undecodable codec on iOS). It is unchanged.
The new function keeps going and returns the failures as data (I-17):

```swift
let report = try await discoverVideosReportingFailures(in: folder, recursive: true)
for video in report.videos { /* inspected VideoInput values, filename order */ }
for failure in report.failures { print("Skipped \(failure.url.lastPathComponent): \(failure.error)") }
```

It still throws for a bad `metadataConcurrency`, a folder that can't be enumerated, and with
`CancellationError` when the task is cancelled. Cancellation is never reported as a per-file failure.

## 4. Upgrade checklist

1. Change the dependency to `from: "1.10.0"` and resolve packages.
2. Build. Nothing should break.
3. If your headers list `.colorPalette`, look at one mosaic: the swatches now appear.
4. Optionally move folder scans that abort on one bad file to `discoverVideosReportingFailures`.

## 5. Known issue

Native preview export can still stall under macOS background scheduling (I-26), as in earlier
releases. See the `PreviewExporting` article, section "macOS Background Scheduling".
