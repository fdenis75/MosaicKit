# Migrating to MosaicKit 1.18.0

This guide is for apps that already use MosaicKit 1.17.x. 1.18.0 opens MPEG transport streams
that have no `.ts` extension (I-38). There is no public API or configuration change, the defaults
are unchanged, and no output name changes.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| opens download links or extensionless files | [2.1](#21-container-sniffing) | None (one extra 1 KB request per new link) |
| shows or matches on error messages for unreadable sources | [2.2](#22-unsupported-ts-codecs) | Check how you show `VideoError.unsupportedCodec` |
| anything else | — | None |

## 2. Changes

### 2.1 Container sniffing

A source whose path has no known video extension (`mp4 m4v mov qt 3gp 3g2 mts m2ts ts m3u8`), such
as `https://host/download/?fid=…` or a local file named `download`, is identified from its first
1 KB:

- An MPEG transport stream (188-byte TS or 192-byte M2TS packets) is opened as `video/mp2t`. In
  1.15–1.17 every such remote URL was forced to `video/mp4`, so a TS link failed with "Cannot Open".
- An MP4/QuickTime file is opened as `video/mp4`, as before.
- Anything else: a remote URL keeps the `video/mp4` default; a local file is left to AVFoundation,
  as before.

For a remote source this is one `Range: bytes=0-1023` request, made once per URL per process (the
result is cached). It also applies with `reduceSourceReads`. A source with a known extension is
never read for this.

### 2.2 Unsupported TS codecs

AVFoundation's transport-stream demuxer reads H.264 and MPEG-2 video only. A TS source with HEVC,
AV1 or MPEG-4 Part 2 video (sniffed, or named `.ts`, `.m2ts` or `.mts`) now fails with:

```swift
VideoError.unsupportedCodec(url, "an MPEG transport stream whose video isn't H.264 or MPEG-2 (HEVC and AV1 in TS can't be read)")
```

The case existed before (H.264 High 10 on iOS), so no new `switch` case is needed. The error comes
from `VideoInput(from:)` and, if you build a `VideoInput` with known metadata yourself, from
`generate(for:config:)` before frame extraction. Before 1.18 these sources failed with "Cannot
Open" or `MosaicError.invalidVideo("Source contains no video track")`.

Reading HEVC-in-TS (for example through ffmpeg on macOS) isn't supported yet.

## 3. Tessera checklist

- Bump MosaicKit to `1.18.0` in `project.yml`.
- No code change is required. Optionally show `VideoError.unsupportedCodec` as "This video's
  format isn't supported" rather than a generic failure.
- Download links to H.264/MPEG-2 `.ts` files now make mosaics; HEVC `.ts` links fail with the
  error above.
