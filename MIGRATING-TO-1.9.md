# Migrating to MosaicKit 1.9.0

This guide is for apps that already use MosaicKit 1.8.x. It lists every change in 1.9.0 that can
break or change the behavior of code that uses the library, who is affected, and what to change.
Coming from 1.7.x? Read [MIGRATING-TO-1.8.md](MIGRATING-TO-1.8.md) first.

**Short version.** 1.9.0 has **two rare source-level breaks** (a new `VideoError` case, and a
changed signature of `PreviewConfiguration.generateFilename(for:)`), **five behavior changes**,
and **one new deprecation** (`LayoutType.dynamic`). Most apps need no code changes, but apps that
look for existing preview or mosaic files by name will notice the naming changes.

Every statement was checked against the code at tags `1.8.0` and `1.9.0`. The only differences in
the public API surface are the ones listed in section 2.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| switches over `VideoError` without a `default:` | [2.1](#21-videoerror-has-a-new-case) | **Build error** |
| passes `generateFilename(for:)` around as a function reference | [2.2](#22-previewconfigurationgeneratefilenamefor-gained-a-parameter) | **Build error** |
| predicts, parses or searches for preview file names | [3.1](#31-preview-default-file-names-no-longer-contain-a-timestamp) | Files not found, previews regenerated once |
| uses `{aspectRatio}` in a directory or file name template, or builds those paths itself | [3.2](#32-aspectratio-renders-as-16-9) | Outputs move |
| uses `LayoutType.dynamic`, or lists `LayoutType.allCases` | [3.3](#33-layouttypedynamic-is-deprecated-and-laid-out-as-custom) | Different layout, warning |
| uses `LayoutType.auto` | [3.4](#34-auto-layout-works-in-pixels) | Different canvas size (fixed on iPhone) |
| runs on iOS with user-supplied videos | [3.5](#35-ios-rejects-undecodable-h264-at-inspection) | Error thrown earlier, with a new type |

Not affected: defaults, the configuration format (everything saved by 1.8.x decodes), the video
and image encoders, the concurrency and cancellation behavior, and throughput.

## 2. Source-level breaks (your code stops compiling)

### 2.1 `VideoError` has a new case

`VideoError.unsupportedCodec(URL, String)` is new ([3.5](#35-ios-rejects-undecodable-h264-at-inspection)).
An exhaustive `switch` over `VideoError` without a `default:` no longer compiles.

```swift
switch error {
case .fileNotFound, .accessDenied: …
// …
case .unsupportedCodec(let url, let codec):          // add this
    show("\(url.lastPathComponent) uses \(codec), which this device cannot decode. Re-encode it.")
}                                                    // or add a default: case
```

`VideoError` was never thrown by the library before 1.9.0 (it is thrown only on iOS, by this new
check), so apps that handle only `MosaicError` and `PreviewError` are unaffected.

### 2.2 `PreviewConfiguration.generateFilename(for:)` gained a parameter

The method is now `generateFilename(for:referenceDate:)`, with `referenceDate` defaulting to
`Date()`. Normal calls compile unchanged:

```swift
let name = config.generateFilename(for: video)        // still fine
```

An unapplied reference no longer resolves, because the full name changed:

```swift
let make = config.generateFilename(for:)              // error in 1.9.0
let make: (VideoInput) -> String = { config.generateFilename(for: $0) }   // fix
```

## 3. Behavior changes (your code compiles, but results differ)

### 3.1 Preview default file names no longer contain a timestamp

The default preview name was `_preview_<name>_<config>_<yyyy-MM-dd_HH-mm-ss>_.<ext>`. It is now
`_preview_<name>_<config>.<ext>`: the same configuration and input always give the same name.

**What you gain.** `overwrite == false` now really skips a preview that already exists. Before, the
name changed on every run, so the existing-file check could never match.

**You are affected if** you:

- search for, delete or index previews by their old names, or parse the timestamp out of them;
- expect a new file on every run. With `overwrite == false` a second run now returns the existing
  file and exports nothing; with `overwrite == true` it replaces it.
- have previews on disk from 1.8.x: they are not recognized and are regenerated **once**. Delete the
  old timestamped files if you want to reclaim the space.

**Fix.** Ask the library for the name instead of rebuilding it:

```swift
let dir = config.generateOutputDirectory(for: video)
let url = dir.appendingPathComponent(config.generateFilename(for: video))
```

If you want a timestamp, opt in with the `{time}` token (`HH-mm-ss`) of `filenameTemplate`, for
example `"{name}_{date}_{time}"`. A template with `{time}` never matches an earlier run, so don't
combine it with `overwrite == false` if you want skipping. Pass a fixed `referenceDate` to
`generateFilename(for:referenceDate:)` when you need the same name twice for one logical save.

### 3.2 `{aspectRatio}` renders as `16-9`

In `MosaicConfiguration` directory and file name templates, the `{aspectRatio}` token used to
insert the raw value (`16:9`). A colon shows as `/` in Finder and is invalid on SMB and exFAT shares.
It now renders `16-9` (also `4-3`, `1-1`, `21-9`, `9-16`), the same form `configurationHash` always
used. Animated images take their name from the mosaic name, so they move too.

**You are affected if** a template contains `{aspectRatio}`, or your code looks up an existing
output path built from `AspectRatio.rawValue`. Mosaics already on disk are not moved; new runs write
to the new path, so with `overwrite == false` they are generated again.

**Fix.** Build the path the same way the library does, or use the library's own helpers
(`generateOutputDirectory(rootDirectory:videoInput:)`, `generateFilename(originalFilename:videoInput:)`,
`animatedOutputURL(for:)`). If you must produce the old form, `rawValue` still returns `16:9`;
replace `:` with `-` to match the new paths.

### 3.3 `LayoutType.dynamic` is deprecated and laid out as `.custom`

The `.dynamic` algorithm produced overlapping rows and clipped cells (I-8). It is removed; the case
stays so that saved configurations still decode, and it is laid out exactly like `.custom`. A
one-time warning is logged on first use, and using `.dynamic` in source gives a deprecation warning.
The case is removed in 2.0.

**You are affected if** you use `.dynamic` (your mosaics change to the `.custom` layout), or you
build a layout picker from `LayoutType.allCases` (it now lists four types: `.auto`, `.custom`,
`.classic`, `.iphone`; before it also listed `.dynamic`).

**Fix.** Replace `.dynamic` with `.custom`. Keep reading old `"dynamic"` values from stored
configurations; they keep working.

### 3.4 `.auto` layout works in pixels

`.auto` mixed points and pixels (I-9). On an iPhone the minimum cell (160 points × scale) was wider
than the screen in points, which gave 0 columns, an empty layout, and an "Empty mosaic layout"
error. It now measures everything in pixels, always allows at least one cell per axis, and picks at
least 4 frames automatically.

**You are affected if** you use `.auto`:

- on iPhone it now works;
- on a Mac or iPad the canvas (`MosaicLayout.mosaicSize`) is now the screen's **pixel** size, so
  it is `scale` times larger than before (for example 3024 px wide on a 2x display where it used to
  be 1512). The grid the algorithm picks can differ too, because its scores are now computed in
  pixels.

**Fix.** If you relied on the smaller canvas, choose `.custom` or `.classic` with an explicit
`MosaicConfiguration.width` instead of `.auto`; they do not depend on the screen.

### 3.5 iOS rejects undecodable H.264 at inspection

iOS decodes 8-bit 4:2:0 H.264 (Baseline, Main, High). It cannot decode High 10, High 4:2:2 or High
4:4:4, so before 1.9.0 every frame extraction of such a file failed, with a generic
frame-extraction error, after the work had started. Inspection (`VideoInput(from:)`,
`VideoSource.inspect`) now reads the codec profile and throws
`VideoError.unsupportedCodec(URL, String)` right away. The string names the profile (for example
`H.264 High 10`), and `recoverySuggestion` says to re-encode as 8-bit H.264 (High or lower) or
HEVC. Every sample description of the track is checked, not only the first.

**You are affected if** your app runs on iOS and accepts videos from the user (camera roll
exports, drone footage, editing software output, 10-bit camera files).

- macOS and Mac Catalyst are unchanged: they decode these profiles, so nothing is thrown there.
- HEVC, including Main 10, is not checked.
- Videos you wrap yourself, with `VideoInput(url:…)` or supplied metadata, skip inspection and are
  not checked; they still fail later, as before.

**Fix.** Handle the new error where you inspect, and show the message instead of a generic failure:

```swift
do {
    let video = try await VideoInput(from: url)
} catch let error as VideoError {
    if case .unsupportedCodec(_, let codec) = error {
        presentAlert("This video uses \(codec). Re-encode it as 8-bit H.264 or HEVC and try again.")
    } else {
        presentAlert(error.localizedDescription)
    }
}
```

## 4. Upgrade checklist

1. Change the dependency to `from: "1.9.0"` and resolve packages.
2. Build. Fix an exhaustive `switch` over `VideoError` ([2.1](#21-videoerror-has-a-new-case)) and any
   function reference to `generateFilename(for:)` ([2.2](#22-previewconfigurationgeneratefilenamefor-gained-a-parameter)).
3. Search your code for places that build or parse preview and mosaic paths by hand
   ([3.1](#31-preview-default-file-names-no-longer-contain-a-timestamp),
   [3.2](#32-aspectratio-renders-as-16-9)) and use the library's helpers instead.
4. Replace `.dynamic` with `.custom` and review any picker built from `LayoutType.allCases`
   ([3.3](#33-layouttypedynamic-is-deprecated-and-laid-out-as-custom)).
5. If you use `.auto`, check the canvas size you expect ([3.4](#34-auto-layout-works-in-pixels)).
6. On iOS, handle `VideoError.unsupportedCodec` where you inspect videos
   ([3.5](#35-ios-rejects-undecodable-h264-at-inspection)).
7. Expect one round of regenerated previews and mosaics after the naming changes.

## 5. Known issue

Native preview export can still stall under macOS background scheduling (I-26), as in 1.8.0. See
the `PreviewExporting` article, section "macOS Background Scheduling".

## 6. Changes in 1.9.1

1.9.1 is a patch release for apps on 1.9.0. It changes no public API and no output file names. It
changes behavior in four places that matter only if you use the settings below.

| If your app… | Change | What to do |
|---|---|---|
| exports previews with no explicit `exportPresetName` (configs decoded without that key, or set to `nil`) | `compressionQuality` now maps to a native preset by **range**. Before, only the exact values 1.0, 0.9, 0.8, 0.7, 0.5 and 0.4 matched; any other value (for example 0.85 or 0.6) silently exported as Passthrough. The values that worked before keep their preset. Only qualities below 0.35 still map to Passthrough. | Set `exportPresetName` explicitly if you need a specific preset. Expect different output for qualities that used to fall through. |
| exports with `exportMode: .sjs` and `sJSExportPresetName == nil` | The codec is chosen by quality range (0.875+ HEVC, 0.625+ H.264 High, 0.375+ Main, below Baseline). `PreviewConfiguration.exportDescription` now reports that same codec (it used to say HEVC), and the output size is the size the video composition renders. For portrait sources the old size was squeezed (about 607×1080 instead of 1080×1920). | Nothing, unless you pinned the old output. With an explicit preset only the size fix applies. |
| saves `ColorDNAConfig` or draws the Color DNA strip | A decoded `height` below 8 (including `0`) is clamped to 8, so the strip is drawn. It used to be silently skipped. A non-finite height is treated as 8. | Remove any workaround that detected a missing strip. |
| reads logs | When a Color DNA strip or watermark is requested but not drawn, `MetalMosaicGenerator` logs a warning under `com.mosaicKit` and still returns the mosaic. | Nothing. |

Documentation only: `VideoInput(url:…)` never throws and returns only the values you passed when
inspection fails. Prefer `VideoInput(from:)` or `VideoSource(url:title:).inspect()`.
