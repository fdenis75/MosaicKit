# Migrating to MosaicKit 1.12.0

This guide is for apps that already use MosaicKit 1.11.x. 1.12.0 adds one layout type,
`LayoutType.uneven`, which shows frames at several sizes. Nothing is removed or renamed, every
existing layout renders as before, and output names of existing configurations do not change.
Coming from 1.10.x or earlier? Read [MIGRATING-TO-1.11.md](MIGRATING-TO-1.11.md) first.

Checked against `git diff 1.11.0 <release commit> -- Sources` before tagging: the
public API differs only by the new enum case (section 2.1). Everything else in the diff is internal.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| has an exhaustive `switch` over `LayoutType` (no `default`) | [2.1](#21-layouttype-has-a-new-case) | **Does not compile** until you add an `.uneven` branch |
| lists layouts with `LayoutType.allCases` (a picker, a settings screen) | [2.2](#22-layouttypeallcases-lists-uneven) | `.uneven` appears; it works without extra settings |
| saves configurations and may read them with an older MosaicKit | [2.3](#23-uneven-configurations-do-not-decode-in-111) | A saved `.uneven` config fails to decode in 1.11 |
| uses `.fixedGrid` with a fixed header taller than about 10 % of the width | [2.4](#24-fixed-grid-reserves-a-tall-fixed-header) | Grids near the 16,384 px height limit now shrink instead of failing |
| wants a mosaic with tiles of several sizes | [3](#3-new-uneven-tiles-layout) | New API |

Everything else is unchanged: defaults, the configuration format, output file names and locations
of existing layouts, errors, cancellation, and throughput (checked with an A/B/A benchmark in U-3).

## 2. Source and behavior changes

### 2.1 `LayoutType` has a new case

`LayoutType.uneven` is new. An exhaustive `switch layoutType { … }` without `default` stops
compiling. Add a branch:

```swift
switch layout.layoutType {
case .custom, .classic, .auto, .iphone, .dynamic: label = layout.layoutType.rawValue
case .fixedGrid: label = "\(layout.grid?.rows ?? 0) × \(layout.grid?.columns ?? 0) grid"
case .uneven: label = "Uneven tiles"
}
```

### 2.2 `LayoutType.allCases` lists `.uneven`

`allCases` is now `[.auto, .custom, .classic, .iphone, .fixedGrid, .uneven]`. Unlike `.fixedGrid`,
`.uneven` needs no extra configuration, so a picker built from `allCases` can offer it as is.

### 2.3 Uneven configurations do not decode in 1.11

1.12 decodes every configuration saved by earlier versions, and other configurations encode exactly
as before. A configuration with `layoutType: "uneven"` cannot be decoded by 1.11 or earlier
(unknown raw value). Only matters if a file is shared between app versions.

### 2.4 Fixed grid reserves a tall fixed header

`.fixedGrid` with `.adaptCanvas` keeps the canvas below the texture limit by reserving room for the
header. With `overlay.header.height = .fixed(h)` the reserve is now at least `h` (it was always
`0.10 × width + 32`). A grid whose canvas plus header would have exceeded 16,384 px, and so failed
at render time, is now planned a little shorter. Every other grid is unchanged.

## 3. New: uneven tiles layout

```swift
var config = MosaicConfiguration(width: 5120, density: .m)
config.layout.layoutType = .uneven
// or
config.layout = LayoutConfiguration(aspectRatio: .widescreen, layoutType: .uneven)
```

- **What it draws:** a bento grid of unit tiles with the video's aspect ratio. Larger tiles are
  2 × 2, 3 × 3 … blocks of unit tiles, so they have the video's aspect too: no frame is cropped,
  stretched or letterboxed, and the grid has no holes. Tiles are numbered in reading order, which
  is time order (frame labels and the ColorDNA strip stay chronological).
- **Density** sets the frame count exactly as for `.custom`, and the largest tile: `XXL`/`XL` 2 ×,
  `L`/`M` 3 ×, `S`/`XS` 4 ×, `XXS` 5 ×. A grid that is too small for that size uses smaller tiles
  (no tile is more than half the shorter side). The tile count lands within a few percent of the
  requested count.
- **Canvas:** the width is exact; the height follows whole tiles, usually within 1–2 % of
  `width / aspectRatio` from about 100 frames up (more at low frame counts or very different
  source and target aspects). The configured aspect is snapped to the nearest preset afterwards, as
  for `.custom`. Gutters are 4 px along the video's long side and `4 / aspect` px along the other.
- **Limits:** unit tiles are at least 120 px wide, and the canvas plus header and ColorDNA strip
  stays within 16,384 px; when either limit binds, the frame count drops.
- **Fallbacks:** fewer than 12 frames, or a source aspect outside 0.2…5, use `.classic`.
  `forIphone: true` still selects the iPhone layout.
- **Output folder:** the hash ends in `_uneven` (`5120_M_16-9_uneven`), so nothing collides with
  existing output.
- **Speed:** each frame is decoded at its own tile size, tile sizes in parallel. Measured against
  `.custom` at the same width and density: about 1.03–1.06 × at concurrency 1 for 5120 px M, and
  on par at 10,000 px XS.
- **Determinism:** the same video and configuration always give the same layout.

## 4. Tessera checklist

1. Bump MosaicKit to `from: "1.12.0"` in `project.yml`.
2. Add `.uneven` to any exhaustive `switch` over `LayoutType` (section 2.1).
3. If a layout picker filters `allCases`, decide whether to show `.uneven` (it needs no other
   control).
4. Optional: offer `.uneven` in the CLI's layout option (raw value `uneven`).
