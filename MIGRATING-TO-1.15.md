# Migrating to MosaicKit 1.15.0

This guide is for apps that already use MosaicKit 1.14.x. 1.15.0 makes remote download links work
as sources (I-30). Nothing is removed or renamed. Output names of local files do not change.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| only processes local files | — | None |
| passes `https` URLs (cloud-drive or download links) as sources | [2.1](#21-remote-download-links-open), [2.2](#22-remote-sources-need-a-local-output-folder), [2.3](#23-output-names-of-extensionless-remote-urls) | Behavior change |
| builds output names itself from `video.url.deletingPathExtension().lastPathComponent` | [2.3](#23-output-names-of-extensionless-remote-urls) | Use `video.outputBaseName` to match MosaicKit |

## 2. Source and behavior changes

### 2.1 Remote download links open

A remote URL whose path has no video extension (`mp4 m4v mov qt 3gp 3g2 mts m2ts ts m3u8`), such
as `https://host/download/?fid=…` served as `application/octet-stream`, used to fail inspection
with AVFoundation's "Cannot Open". MosaicKit now creates every asset for such a URL with
`AVURLAssetOverrideMIMETypeKey: "video/mp4"`, so MP4 and QuickTime content opens. Other
containers behind such a link (MKV, WebM, …) still fail.

For an `http(s)` source, inspection also sends one range request (`Range: bytes=0-0`) to read the
file size, so `VideoInput.fileSize` and `metadata.bitrate` are filled. A failed request leaves them
`nil`; it never fails inspection.

### 2.2 Remote sources need a local output folder

Outputs went next to the source by default, which is not a folder for an `https` URL. Now
`MetalMosaicGenerator.generate` and `PreviewVideoGenerator.generate` throw
`MosaicError.invalidConfiguration` / `PreviewError.invalidConfiguration` before any I/O when the
resolved output directory is not a file URL. Set `MosaicConfiguration.outputdirectory` /
`PreviewConfiguration.outputDirectory` (or an absolute `outputDirectoryTemplate`). You can check
up front with `config.validateOutputLocation(for: video)`.

### 2.3 Output names of extensionless remote URLs

📁 Every link of a download service ended in `/download/`, so every mosaic was named `download_…`
and, with `overwrite == false`, the second video returned the first one's mosaic. The name now
comes from `VideoInput.outputBaseName`:

- local file, or remote URL with a video extension: the file name without extension (unchanged);
- other remote URL: the `title` you passed (when it differs from the last path component),
  otherwise `<last path component>-<first 8 hex digits of SHA-256(url)>`, e.g. `download-1a2b3c4d`.

Signed links often change on every refresh, which changes the hash. Pass a `title` (or a `postID`)
for names that stay stable:

```swift
let input = try await VideoSource(url: downloadLink, title: "Holiday").inspect()
var config = MosaicConfiguration()
config.outputdirectory = outputFolder
let mosaicURL = try await MetalMosaicGenerator().generate(for: input, config: config)
```

Preview and thumbnail-export names use the same base name.
