# Migrating to MosaicKit 1.17.0

This guide is for apps that already use MosaicKit 1.16.x. 1.17.0 adds an opt-in low-data mode for
mosaics of remote sources (I-33). Nothing is removed or renamed, the defaults are unchanged, and no
output name changes.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| doesn't set the new option | — | None |
| makes mosaics or animations of `http`/`https` sources and wants to download less | [2.1](#21-reducesourcereads) | Opt-in |
| exposes `useAccurateTimestamps` in its settings | [2.2](#22-validation) | Handle a new validation error |
| saves `MosaicConfiguration` as JSON | [2.3](#23-saved-configurations) | None (new key, decoded with a default) |

## 2. Changes

### 2.1 `reduceSourceReads`

`MosaicConfiguration.reduceSourceReads` (`Bool`, default `false`). When `true`:

- An `http`/`https` source is read through MosaicKit's own resource loader, which fetches small
  byte ranges only when a frame needs them (192 KB, then 64 KB at a time). AVFoundation's own
  loader reads about 0.5 MB ahead on every seek. Measured at 25 Mbit/s, one mosaic of a 10-minute
  1080p, 6 Mbit/s source drops from 35 MB to 17 MB (about three times as many, smaller requests),
  and of a 4K source with 4 s between keyframes from 215 MB to 20 MB.
- Every frame of the mosaic, the animation and the header's palette swatches is taken from the
  nearest keyframe. A frame can move from its sampled time by up to half the keyframe interval, and
  when keyframes are farther apart than the sampled frames, neighboring tiles show the same frame.
  Frame labels show the time of the frame actually used.
- A local file keeps AVFoundation's loader; only the keyframe snapping applies.
- Previews (`PreviewConfiguration`) aren't affected.
- The server must support byte-range requests (HTTP 206). If it doesn't, generation fails with
  `MosaicError.processingFailed` naming the option; turn it off for that source.

```swift
var config = MosaicConfiguration()
config.outputdirectory = outputFolder   // required for remote sources since 1.15
config.reduceSourceReads = true
let url = try await MetalMosaicGenerator().generate(for: input, config: config)
```

It isn't part of `configurationHash`, like `useAccurateTimestamps`: switching it doesn't move outputs,
and with `overwrite == false` an existing mosaic made without it is kept.

### 2.2 Validation

`reduceSourceReads` and `useAccurateTimestamps` can't both be `true`:
`MosaicConfiguration.validate()` throws `MosaicError.invalidConfiguration`. If your settings expose
both, disable one when the other is on.

### 2.3 Saved configurations

The new `reduceSourceReads` key is encoded; configurations saved without it decode with `false`.

### 2.4 `minimal()`

`MosaicConfiguration.minimal()` returns a copy with no metadata header, a solid background
(`useMovieColorsForBg = false`) and no ColorDNA strip. It doesn't reduce reads, except that it skips
the palette-swatch pass of a header with a `.colorPalette` field.

## 3. Tessera checklist

1. Bump MosaicKit to 1.17.0 in `project.yml`.
2. Optionally add a "Reduce data use" setting for remote sources that sets `reduceSourceReads`, and
   make it exclusive with "Accurate timestamps".
