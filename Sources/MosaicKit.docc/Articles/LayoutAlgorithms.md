# Layout Algorithms Comparison

Understanding the layout algorithms and choosing the right one for your use case.

## Overview

MosaicKit provides six layout algorithms (plus the deprecated `.dynamic`), each optimized for different use cases and visual aesthetics. This guide explains how each algorithm works and when to use it.

## Layout Algorithm Overview

| Algorithm | Best For | Characteristics |
|-----------|----------|-----------------|
| **Custom** | Most videos | Three-zone layout, centered large thumbnails |
| **Classic** | Traditional grid | Uniform spacing, consistent sizing |
| **Auto** | Screen-aware | Adapts to display dimensions |
| **Dynamic** (deprecated) | — | Laid out as Custom; removed in 2.0 |
| **iPhone** | Mobile viewing | Vertical scrolling, fixed width |
| **Fixed Grid** | A chosen number of frames | Exactly rows × columns, four fit modes |
| **Uneven** | Picking out a few frames | Tiles in several sizes, none cropped or distorted |

## Custom Layout

### Description

The custom layout algorithm divides the mosaic into three horizontal zones with different thumbnail sizes: small thumbnails on top, large thumbnails in the center, and small thumbnails on the bottom.

### Algorithm

```swift
// 1. Divide mosaic into 3 zones
let zones = [
    topZone: 0.25 * totalHeight,    // 25% - small thumbnails
    centerZone: 0.50 * totalHeight,  // 50% - large thumbnails
    bottomZone: 0.25 * totalHeight   // 25% - small thumbnails
]

// 2. Calculate thumbnail sizes based on target aspect ratio
let largeRatio = targetAspectRatio * 1.2  // 20% larger
let smallRatio = targetAspectRatio * 0.8  // 20% smaller

// 3. Optimize layout to minimize thumbnail count difference
while abs(smallCount - largeCount) > threshold {
    adjustZoneSizes()
}
```

### Visual Representation

```
┌─────────────────────────────────┐
│  Small  │  Small  │  Small      │  Top Zone (25%)
├─────────────────────────────────┤
│                                 │
│   Large    │    Large           │  Center Zone (50%)
│                                 │
├─────────────────────────────────┤
│  Small  │  Small  │  Small      │  Bottom Zone (25%)
└─────────────────────────────────┘
```

### Configuration

```swift
let config = MosaicConfiguration(
    layout: LayoutConfiguration(
        aspectRatio: .widescreen,  // 16:9
        layoutType: .custom
    )
)
```

### Best For

- General-purpose video mosaics
- Balancing visual interest with information density
- Videos where center frames are most important
- Professional presentations

### Parameters

- **Aspect Ratio**: Determines thumbnail proportions
- **Density**: Controls total thumbnail count
- **Spacing**: Adjusts gaps between thumbnails (default: 4px)

## Classic Layout

### Description

Traditional grid layout with uniform thumbnail sizes and consistent spacing. Thumbnails are arranged in rows and columns with equal dimensions.

### Algorithm

```swift
// 1. Calculate optimal grid dimensions
let aspectRatio = mosaicWidth / (mosaicWidth / targetAspectRatio)
let cols = ceil(sqrt(thumbnailCount * aspectRatio))
let rows = ceil(thumbnailCount / cols)

// 2. Calculate thumbnail size
let spacing = 4.0
let thumbnailWidth = (mosaicWidth - (cols + 1) * spacing) / cols
let thumbnailHeight = thumbnailWidth / videoAspectRatio

// 3. Position thumbnails in grid
for (index, thumbnail) in thumbnails.enumerated() {
    let col = index % cols
    let row = index / cols
    let x = spacing + col * (thumbnailWidth + spacing)
    let y = spacing + row * (thumbnailHeight + spacing)
}
```

### Visual Representation

```
┌───────────────────────────────┐
│ □ │ □ │ □ │ □ │ □ │ □ │ □     │
│ □ │ □ │ □ │ □ │ □ │ □ │ □     │
│ □ │ □ │ □ │ □ │ □ │ □ │ □     │
│ □ │ □ │ □ │ □ │ □ │ □ │ □     │
│ □ │ □ │ □ │ □ │ □ │ □ │ □     │
└───────────────────────────────┘
```

### Configuration

```swift
let config = MosaicConfiguration(
    layout: LayoutConfiguration(
        aspectRatio: .widescreen,
        layoutType: .classic,
        spacing: 4
    )
)
```

### Best For

- Simple, clean aesthetic
- Maximum information density
- Contact sheets and catalogs
- Archival purposes

## Auto Layout

### Description

Screen-aware layout that automatically adapts to the display size. Queries the system for the main screen dimensions and optimizes the mosaic to fit.

### Algorithm

```swift
// 1. Get screen dimensions
let screenSize = NSScreen.main?.visibleFrame.size  // macOS
let screenSize = UIScreen.main.bounds.size         // iOS

// 2. Calculate scale factor
let targetWidth = screenSize.width * screenScale
let targetHeight = targetWidth / targetAspectRatio

// 3. Optimize thumbnail count for screen
let optimalCount = calculateOptimalCount(
    for: targetWidth,
    screenHeight: targetHeight,
    videoAspectRatio: videoAspectRatio
)
```

### Visual Representation

Screen-dependent, adapts to:
- **4K Display**: Larger mosaic, more thumbnails
- **1080p Display**: Medium mosaic, balanced count
- **Mobile Screen**: Smaller mosaic, fewer thumbnails

### Configuration

```swift
let config = MosaicConfiguration(
    layout: LayoutConfiguration(
        layoutType: .auto  // No aspect ratio needed
    )
)
```

### Best For

- Desktop applications with varying screen sizes
- Full-screen mosaic viewing
- Presentations on unknown display configurations
- Adaptive UIs

## Dynamic Layout (deprecated)

`LayoutType.dynamic` is deprecated and is removed in 2.0. Its algorithm produced overlapping rows and clipped cells, so it is now laid out exactly like ``LayoutType/custom``. Configurations that stored `"dynamic"` still decode, and a one-time warning is logged. Use `.custom` instead.

## iPhone Layout

### Description

Mobile-optimized vertical layout with fixed width and vertical scrolling. Designed for viewing on iPhone screens in portrait orientation.

### Algorithm

```swift
// 1. Fixed width for mobile screen
let thumbnailWidth: CGFloat = 375  // iPhone standard width

// 2. Calculate height maintaining aspect ratio
let thumbnailHeight = thumbnailWidth / videoAspectRatio

// 3. Stack vertically with minimal spacing
var yOffset: CGFloat = headerHeight
for thumbnail in thumbnails {
    positions.append(CGPoint(x: 0, y: yOffset))
    yOffset += thumbnailHeight + spacing
}

// 4. Total height = sum of all thumbnails + spacing
let totalHeight = yOffset
```

### Visual Representation

```
┌─────────────┐
│   Header    │
├─────────────┤
│             │
│  Thumbnail  │  ← Full width
│             │
├─────────────┤
│             │
│  Thumbnail  │
│             │
├─────────────┤
│             │
│  Thumbnail  │
│             │
├─────────────┤
│      ⋮      │
│   (scroll)  │
│      ⋮      │
└─────────────┘
```

### Configuration

```swift
let config = MosaicConfiguration(
    width: 375,  // iPhone width
    layout: LayoutConfiguration(
        aspectRatio: .vertical,  // 9:16
        layoutType: .iphone,
        spacing: 2  // Minimal spacing
    ),
    density: .l  // Medium density for scrolling
)
```

### Best For

- Mobile app integration
- Instagram/social media sharing
- Vertical scrolling interfaces
- Touch-based navigation

## Fixed Grid Layout

### Description

`LayoutType.fixedGrid` lays out exactly `rows × columns` cells, in time order, with frames sampled evenly across the video. Density does not change the frame count.

### Fit modes

`GridSpecification.fit` decides how the grid meets the canvas:

- `.adaptCanvas` (default): the canvas follows the grid. Every cell has the video's aspect ratio, so no frame is distorted, cropped or letterboxed. `MosaicConfiguration.width` is a maximum: the canvas is trimmed to whole cells and shrunk if the grid would exceed the 16,384 px texture limit.
- `.stretch`: the canvas keeps the configured `AspectRatio`, header and ColorDNA strip included, so the final image is `width × round(width / aspect)`. The cells must be within `aspectTolerance` (2 % by default) of the video's aspect, otherwise the request fails with `FixedGridIssue/aspectMismatch` and up to three grids that would work.
- `.letterbox`: same canvas, but a cell that does not match gets bars instead of a stretched picture. It fails with `FixedGridIssue/fillTooLow` when the picture would fill less than `minimumFill` (50 %) of the cell.
- `.crop`: same canvas, but the cell is filled: each frame is cut to the cell's aspect, keeping the center, and the request fails with `FixedGridIssue/fillTooLow` when less than `minimumFill` of the picture would survive.

### Planning without a video

``LayoutProcessor/planFixedGrid(_:sourceAspectRatio:mosaicAspectRatio:mosaicWidth:spacing:reservedHeight:overlayHeight:)`` is pure and never throws; it returns a ``FixedGridPlan`` (a layout with notes, or a ``FixedGridIssue`` with suggestions), which is enough to draw a live preview.

For the fixed-aspect modes the header and the ColorDNA strip are subtracted from the grid area, so the planner needs their exact height in `overlayHeight`:

- compute the header height with ``ThumbnailProcessor/metadataHeaderHeight(for:width:height:thumbnailHeight:forIphone:headerConfig:)``, passing `thumbnailHeight: width / 20` (the fixed-aspect header is sized from `W/20`), and add the ColorDNA strip height when it is shown;
- use ``LayoutProcessor/fixedGridCanvasWidth(requestedWidth:mosaicAspectRatio:)`` as the `width` for that header: it is the requested width, reduced when a canvas of that width and aspect would be taller than a texture can be.

`.adaptCanvas` ignores `overlayHeight` and only needs `reservedHeight`, an upper bound that keeps the canvas inside the texture limit.

### Configuration

```swift
let layout = LayoutConfiguration.fixedGrid(rows: 4, columns: 6, fit: .letterbox, aspectRatio: .widescreen)
```

### Live preview in SwiftUI

Draw the plan's cells in a `Canvas`: the rectangles are the ones the generator renders, so the preview matches the output. `Examples/FixedGridPreviewExample.swift` in the repository has a complete editor with steppers and a fit-mode picker.

```swift
let plan = LayoutProcessor().planFixedGrid(
    GridSpecification(rows: 4, columns: 6, fit: .crop),
    sourceAspectRatio: 16.0 / 9.0,
    mosaicAspectRatio: .widescreen,
    mosaicWidth: 5120,
    overlayHeight: headerAndStripHeight
)
switch plan {
case .layout(let layout, let effectiveWidth, let notes):
    // layout.positions[i] and layout.thumbnailSizes[i] are the frame rectangles in the grid
    // area (layout.mosaicSize); the header and strip sit above it in the fixed-aspect modes.
    draw(layout, width: effectiveWidth, notes: notes)
case .infeasible(let issue, let suggestions):
    show(issue.explanation, suggestions)   // e.g. "Try 5 × 5"
}
```

## Uneven Tiles Layout

### Description

``LayoutType/uneven`` shows frames at several sizes at once. The canvas is a grid of unit cells
with the video's aspect ratio; a tile covers a `k × k` block of cells, so a larger tile has the
video's aspect too and no frame is ever cropped or distorted. 1 × 1 tiles fill the remaining
cells, so the grid has no holes.

### Algorithm

1. Density gives the frame count (as for Custom) and the largest tile side `x`: `XXL`/`XL` 2,
   `L`/`M` 3, `S`/`XS` 4, `XXS` 5. Larger tiles take about 45 % of the area, split equally
   between sizes 2…`x`. Each frame is decoded at its own tile size.
2. The grid's columns and rows are chosen so the canvas aspect is as close as possible to the
   configured aspect ratio for that many tiles; no tile is larger than half the shorter side.
3. Tiles are placed row by row (lowest, then leftmost free cell). A deterministic schedule
   decides when a larger tile is due and spreads larger tiles across the width; the best of
   eight passes for balance is kept. The same inputs always give the same layout.
4. Tiles are numbered in reading order, which is also time order.

Gutters are 4 px along the video's long side and `4 / aspect` px along the other, which keeps
every multi-cell tile exactly on the video's aspect. The width is exact; unit tiles are at least
120 px wide, and the height stays within the texture limit with the header and ColorDNA strip.

### Fallbacks

- Fewer than 12 frames, or a source aspect outside 0.2…5: the Classic layout.
- `forIphone: true`: the iPhone layout, as for every layout except Fixed Grid.

### Configuration

```swift
var config = MosaicConfiguration(width: 5120, density: .m)
config.layout.layoutType = .uneven
```

## Comparison Matrix

### Thumbnail Count Distribution

For a 60-second video with M density (~100 frames):

| Layout | Small Thumbnails | Large Thumbnails | Total | Rows |
|--------|-----------------|------------------|-------|------|
| Custom | 50 | 50 | 100 | 7-9 |
| Classic | 0 | 100 | 100 | 7 |
| Auto | 0 | 75-150 | 75-150 | Varies |
| iPhone | 0 | 100 | 100 | 100 |
| Fixed Grid (4 × 6) | 0 | 24 | 24 | 4 |
| Uneven (M) | ~90 | ~10–15 (2 × 2 and 3 × 3) | ~100 | ~12–13 |

### Performance Characteristics

| Layout | Calculation Time | Memory Usage | Complexity |
|--------|-----------------|--------------|------------|
| Custom | ~15ms | Medium | High |
| Classic | ~5ms | Low | Low |
| Auto | ~20ms | Medium | Medium |
| iPhone | ~3ms | Low | Low |
| Fixed Grid | Constant (no search except a short binary search for the height limit) | Low | Low |
| Uneven | < 1.5 ms up to 800 frames | Low | Medium |

## Choosing the Right Layout

### Decision Tree

```swift
// For most use cases
let config = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .custom)
)

// For simple grid
let config = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .classic)
)

// For desktop apps
let config = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .auto)
)

// For artistic style
let config = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .custom)
)

// For mobile apps
let config = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .iphone)
)

// For an exact number of frames
let config = MosaicConfiguration(
    layout: .fixedGrid(rows: 4, columns: 6)
)
```

### Use Case Examples

**Professional Video Catalog:**
```swift
MosaicConfiguration(
    width: 5120,
    density: .m,
    layout: LayoutConfiguration(
        aspectRatio: .widescreen,
        layoutType: .classic
    )
)
```

**Social Media Highlight Reel:**
```swift
MosaicConfiguration(
    width: 2048,
    density: .s,
    layout: LayoutConfiguration(
        aspectRatio: .square,
        layoutType: .custom
    )
)
```

**Mobile App Preview:**
```swift
MosaicConfiguration(
    width: 375,
    density: .l,
    layout: LayoutConfiguration(
        aspectRatio: .vertical,
        layoutType: .iphone
    )
)
```

## Advanced Customization

### Combining Layout with Visual Settings

```swift
let layout = LayoutConfiguration(
    aspectRatio: .widescreen,
    spacing: 8,  // Larger gaps
    layoutType: .custom,
    visual: VisualSettings(
        addBorder: true,
        borderColor: .white,
        borderWidth: 2,
        addShadow: true,
        shadowSettings: ShadowSettings(
            opacity: 0.3,
            radius: 6,
            offset: CGSize(width: 0, height: -3)
        )
    )
)

let config = MosaicConfiguration(layout: layout)
```

### Custom Aspect Ratios

```swift
// Square mosaic with custom layout
var config = MosaicConfiguration(
    layout: LayoutConfiguration(aspectRatio: .square, layoutType: .custom)
)

// Ultrawide mosaic
var ultrawideConfig = MosaicConfiguration(
    layout: LayoutConfiguration(
        aspectRatio: .ultrawide,
        layoutType: .custom
    )
)
```

## Testing Different Layouts

Compare layouts for the same video:

```swift
let layouts: [LayoutType] = [.custom, .classic, .auto, .iphone]

for layoutType in layouts {
    let config = MosaicConfiguration(
        layout: LayoutConfiguration(layoutType: layoutType),
        outputdirectory: outputDir
    )

    let outputURL = try await generator.generate(for: video, config: config)

    print("\(layoutType.rawValue) layout saved to: \(outputURL.lastPathComponent)")
}
```

## See Also

- <doc:Architecture>
- ``LayoutProcessor``
- ``LayoutConfiguration``
- ``LayoutType``
- ``AspectRatio``
