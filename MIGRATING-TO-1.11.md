# Migrating to MosaicKit 1.11.0

> **Status: unreleased.** This guide describes `main` after the fixed-grid series (plan G-1 to
> G-6, PRs #68 to #72 and the G-6 docs PR). It becomes final with the 1.11.0 release PR.

This guide is for apps that already use MosaicKit 1.10.x. 1.11.0 adds one layout type,
`LayoutType.fixedGrid`, and the API around it. Nothing is removed or renamed, every existing
layout renders exactly as before, and output names of existing configurations do not change.
Coming from 1.9.x or earlier? Read [MIGRATING-TO-1.10.md](MIGRATING-TO-1.10.md) first.

Checked against the code at tag `1.10.0` and `main` (`git diff 1.10.0 -- Sources`): the public API
differs only by the additions in section 3 and the one source break in section 2.1.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| has an exhaustive `switch` over `LayoutType` (no `default`) | [2.1](#21-layouttype-has-a-new-case) | **Does not compile** until you add a `.fixedGrid` branch |
| lists layouts with `LayoutType.allCases` (a picker, a settings screen) | [2.2](#22-layouttypeallcases-lists-fixedgrid) | `.fixedGrid` appears; it needs a grid to work |
| saves configurations and may read them with an older MosaicKit | [2.3](#23-configurations-with-a-grid-do-not-decode-in-110) | A saved grid config fails to decode in 1.10 |
| wants a mosaic with an exact number of rows and columns | [3](#3-new-fixed-grid-layout) | New API |

Everything else is unchanged: defaults, the configuration format of existing layouts, output file
names and locations, errors, cancellation, and throughput (checked with A/B/A benchmarks in G-2,
G-3 and G-5).

## 2. Source and behavior changes

### 2.1 `LayoutType` has a new case

`LayoutType.fixedGrid` is new. An exhaustive `switch layoutType { … }` without `default` stops
compiling. Add a branch:

```swift
switch layout.layoutType {
case .custom, .classic, .auto, .iphone, .dynamic: label = layout.layoutType.rawValue
case .fixedGrid: label = "\(layout.grid?.rows ?? 0) × \(layout.grid?.columns ?? 0) grid"
}
```

### 2.2 `LayoutType.allCases` lists `.fixedGrid`

`allCases` is now `[.auto, .custom, .classic, .iphone, .fixedGrid]`. Selecting `.fixedGrid` without
setting `LayoutConfiguration.grid` fails validation with
`MosaicError.invalidConfiguration("The fixedGrid layout needs LayoutConfiguration.grid (rows and columns)")`.
A picker built from `allCases` should either show rows, columns and fit controls for `.fixedGrid`,
or filter it out.

### 2.3 Configurations with a grid do not decode in 1.10

A configuration without a grid encodes byte-for-byte as before (`grid` is omitted when `nil`), and
1.11 decodes every configuration saved by earlier versions. A configuration **with**
`layoutType: "fixedGrid"` cannot be decoded by 1.10 or earlier (unknown raw value). Only matters if
a file is shared between app versions.

### 2.4 `forIphone` does not override a grid

`generate(for:config:forIphone: true)` still forces the `.iphone` layout for every other type. With
`.fixedGrid` the grid wins (a message is logged).

## 3. New: fixed grid layout

### 3.1 Configure it

```swift
var config = MosaicConfiguration(width: 5120)
config.layout = .fixedGrid(rows: 4, columns: 6)                         // .adaptCanvas
config.layout = .fixedGrid(rows: 4, columns: 6, fit: .letterbox, aspectRatio: .widescreen, spacing: 4)
// or, field by field:
config.layout.layoutType = .fixedGrid
config.layout.grid = GridSpecification(rows: 4, columns: 6, fit: .crop,
                                       aspectTolerance: 0.02, minimumFill: 0.5)
```

- **Frame count** is exactly `rows × columns`, sampled at equal steps over 5–95 % of the video, in
  row-major time order. `density` is ignored for the count (it still appears in the hash).
- **Fit modes** (`GridFitMode`, raw values persisted):

| `fit` | Canvas | Frames | Rejected when |
|---|---|---|---|
| `.adaptCanvas` (default) | `width` is a maximum; height follows the grid; `aspectRatio` is not used | Source aspect, never altered | frames under 40 px; grid taller than 16,384 px |
| `.letterbox` | exactly `width × round(width/aspect)`, header and ColorDNA strip included | bars around the picture | picture fills less than `minimumFill` of the cell |
| `.crop` | same | fill the cell, center kept | less than `minimumFill` of the picture survives |
| `.stretch` | same | stretched | cell aspect more than `aspectTolerance` off the video's |

  A cell within `aspectTolerance` of the video is simply stretched in every fixed-aspect mode.
- **Limits:** 1…50 rows and columns (`GridSpecification.maximumAxisCount`), at most 1000 cells
  (`maximumCellCount`), frames at least 40 px on their short side (`minimumFrameSide`),
  `aspectTolerance` in 0…0.25, `minimumFill` in 0.1…1, at least 4 cells when `gifMode` is on.
- **Errors:** everything that does not need the video is checked by `MosaicConfiguration.validate()`;
  the rest is checked before any frame is decoded. A grid the caller can change (cells too small,
  too tall, aspect mismatch, fill too low) throws `MosaicError.invalidConfiguration(String)` with
  the numbers and a way out, for example "…Use fit .adaptCanvas, or another grid". A video that
  cannot fill the grid throws `MosaicError.invalidVideo(String)`: unknown dimensions (inspect it
  with `VideoInput(from:)`), or fewer distinct frames than cells (more than 90 % of
  `duration × frameRate`). Catch both if you show the message to the user.
- **Animated exports** use `rows × columns` frames at the source aspect (they are never cropped).

### 3.2 Plan it without a video (live preview)

`LayoutProcessor.planFixedGrid` is pure, cheap and never throws, so an editor can call it on every
change. The rectangles it returns are the ones the generator renders.

```swift
let plan = LayoutProcessor().planFixedGrid(
    GridSpecification(rows: 4, columns: 6, fit: .letterbox),
    sourceAspectRatio: CGFloat(video.aspectRatio ?? 16.0 / 9.0),
    mosaicAspectRatio: .widescreen,
    mosaicWidth: 5120,
    spacing: 4,              // LayoutConfiguration.spacing
    reservedHeight: 0,       // .adaptCanvas: upper bound of header + strip height
    overlayHeight: 0         // fixed-aspect modes: the exact header + strip height
)
switch plan {
case .layout(let layout, let effectiveWidth, let notes):
    // layout.positions / thumbnailSizes: frame rectangles in the grid area (layout.mosaicSize)
    // notes: [FixedGridNote] — .widthReduced, .stretched, .letterboxed(fill:), .cropped(retained:)
case .infeasible(let issue, let suggestions):
    // issue: FixedGridIssue with the numbers; issue.explanation is the English message
    // suggestions: up to three GridSpecifications that would work (fixed-aspect modes)
}
```

For the fixed-aspect modes, `overlayHeight` must be the exact height the header and strip will have:

```swift
let width = LayoutProcessor.fixedGridCanvasWidth(requestedWidth: config.width,
                                                 mosaicAspectRatio: config.layout.aspectRatio)
var overlay = 0
if config.includeMetadata {
    overlay += ThumbnailProcessor(config: config).metadataHeaderHeight(
        for: video, width: width, thumbnailHeight: CGFloat(width) / 20,
        headerConfig: config.overlay.header)
}
if config.overlay.colorDNA.show { overlay += Int(max(ColorDNAConfig.minimumHeight, config.overlay.colorDNA.height)) }
```

A complete SwiftUI editor (steppers, fit picker, `Canvas` drawing, suggestions) is in
[Examples/FixedGridPreviewExample.swift](Examples/FixedGridPreviewExample.swift).

### 3.3 Output names

Existing layouts keep their hash. A grid's hash names the grid, so changing rows, columns, fit,
tolerance or spacing never reuses an older file:

| Layout | `{layout}` token | Example `configurationHash` |
|---|---|---|
| `.fixedGrid`, `.adaptCanvas` | `fixedGrid-<R>x<C>-sp<S>` | `5120_M_16-9_fixedGrid-4x6-sp4` |
| `.fixedGrid`, other fits | `fixedGrid-<R>x<C>-<fit>-tol<T>-sp<S>` | `5120_M_16-9_fixedGrid-4x6-letterbox-tol0.02-sp4` |

### 3.4 New public symbols

| Symbol | Kind |
|---|---|
| `LayoutType.fixedGrid` | enum case |
| `LayoutConfiguration.grid: GridSpecification?`, `init(…, grid:)` (defaults to `nil`) | property, init parameter |
| `LayoutConfiguration.fixedGrid(rows:columns:fit:aspectRatio:spacing:)` | static factory |
| `GridSpecification` (`rows`, `columns`, `fit`, `aspectTolerance`, `minimumFill`, `maximumAxisCount`, `maximumCellCount`, `minimumFrameSide`) | struct, `Codable` |
| `GridFitMode` (`adaptCanvas`, `letterbox`, `crop`, `stretch`) | enum, `Codable` |
| `LayoutProcessor.planFixedGrid(_:sourceAspectRatio:mosaicAspectRatio:mosaicWidth:spacing:reservedHeight:overlayHeight:)` | method |
| `LayoutProcessor.fixedGridCanvasWidth(requestedWidth:mosaicAspectRatio:)` | static method |
| `FixedGridPlan` (`layout`, `infeasible`), `FixedGridIssue` (+ `explanation`), `FixedGridNote` | enums, `Sendable` (not `Codable`) |
| `ThumbnailProcessor.metadataHeaderHeight(for:width:height:thumbnailHeight:forIphone:headerConfig:)` | method |

`FixedGridIssue.fitModeUnavailable` exists but is never produced (every fit mode is implemented);
it stays so `switch`es written during the series keep compiling.
