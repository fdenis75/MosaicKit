# Migrating to MosaicKit 1.13.0

This guide is for apps that already use MosaicKit 1.12.x. 1.13.0 adds one header option and
makes mosaic progress monotonic. Nothing is removed or renamed, and output names do not change.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| shows only the file name in the mosaic header | [2.1](#21-headerconfigfilepathshowsfilenameonly) | New API, opt-in |
| builds `HeaderConfig` with its memberwise-style `init` | [2.1](#21-headerconfigfilepathshowsfilenameonly) | None: the new parameter has a default |
| drives a progress bar from `.creatingMosaic` | [2.2](#22-creatingmosaic-progress-is-002--09-and-monotonic) | Values change; the bar no longer jumps or goes backwards |
| saves configurations | [2.1](#21-headerconfigfilepathshowsfilenameonly) | Old saved configs still decode |

## 2. Source and behavior changes

### 2.1 `HeaderConfig.filePathShowsFileNameOnly`

A header with the `.filePath` field printed `Path: <full path>`. A batch shares one
`MosaicConfiguration`, so an app could not show only the file name through a per-video
`.custom` field. Set the new option instead:

```swift
config.overlay.header.filePathShowsFileNameOnly = true   // "Path: clip.mov"
```

It defaults to `false` (full path, as before). `HeaderConfig` now decodes through a custom
initializer: configurations saved by 1.12.x, without the key, decode with `false`.
`configurationHash` is unchanged for existing configurations.

### 2.2 `.creatingMosaic` progress is 0.02 → 0.9 and monotonic

`MosaicGenerationProgress.progress` for `.creatingMosaic` used to jump from 0 to about 0.745,
climb to about 0.999, and then fall to 0.9 when `.savingMosaic` reported. It now rises from 0.02
to 0.9, and `.savingMosaic` continues with 0.9 then 0.999. If your UI hard-coded the old range
(for example to map the value onto a phase label), update it. No API changed.
