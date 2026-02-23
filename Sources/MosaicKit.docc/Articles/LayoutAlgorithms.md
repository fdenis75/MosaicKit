# Layout Algorithms Comparison

Understanding the five layout algorithms and choosing the right one for your use case.

## Overview

MosaicKit provides five distinct layout algorithms, each optimized for different use cases and visual aesthetics. This guide explains how each algorithm works and when to use it.

## Layout Algorithm Overview

| Algorithm | Best For | Characteristics |
|-----------|----------|-----------------|
| **Custom** | Most videos | Three-zone layout, centered large thumbnails |
| **Classic** | Traditional grid | Uniform spacing, consistent sizing |
| **Auto** | Screen-aware | Adapts to display dimensions |
| **Dynamic** | Artistic style | Center emphasis, variable sizing |
| **iPhone** | Mobile viewing | Vertical scrolling, fixed width |

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

## Dynamic Layout

### Description

Center-emphasized layout with variable thumbnail sizes. Creates visual interest by varying sizes based on position, with larger thumbnails in the center.

### Algorithm

```swift
// 1. Define size zones
let centerZone = 0.4 * mosaicHeight    // 40% center
let transitionZone = 0.3 * mosaicHeight // 30% each side

// 2. Calculate size multipliers
func sizeMultiplier(for position: CGFloat) -> CGFloat {
    let distanceFromCenter = abs(position - 0.5)
    return 1.0 + (1.0 - distanceFromCenter * 2.0) * 0.5
    // Center: 1.5x, Edges: 1.0x
}

// 3. Apply multipliers to create gradient of sizes
for (index, thumbnail) in thumbnails.enumerated() {
    let position = CGFloat(index) / CGFloat(thumbnailCount)
    let multiplier = sizeMultiplier(for: position)
    let size = baseSize * multiplier
}
```

### Visual Representation

```
┌─────────────────────────────────┐
│   □   │   □   │   □   │   □     │  Smaller
├─────────────────────────────────┤
│     ■     │     ■     │     ■   │  Medium
├─────────────────────────────────┤
│         ███       ███           │  Larger (center)
├─────────────────────────────────┤
│     ■     │     ■     │     ■   │  Medium
├─────────────────────────────────┤
│   □   │   □   │   □   │   □     │  Smaller
└─────────────────────────────────┘
```

### Configuration

```swift
let config = MosaicConfiguration(
    layout: LayoutConfiguration(
        aspectRatio: .widescreen,
        layoutType: .dynamic
    ),
    density: .s  // Higher density recommended
)
```

### Best For

- Artistic presentations
- Highlighting key moments (center frames)
- Music videos and creative content
- Visual storytelling

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

## Comparison Matrix

### Thumbnail Count Distribution

For a 60-second video with M density (~100 frames):

| Layout | Small Thumbnails | Large Thumbnails | Total | Rows |
|--------|-----------------|------------------|-------|------|
| Custom | 50 | 50 | 100 | 7-9 |
| Classic | 0 | 100 | 100 | 7 |
| Auto | 0 | 75-150 | 75-150 | Varies |
| Dynamic | 30 | 40 | 100 | 8-10 |
| iPhone | 0 | 100 | 100 | 100 |

### Performance Characteristics

| Layout | Calculation Time | Memory Usage | Complexity |
|--------|-----------------|--------------|------------|
| Custom | ~15ms | Medium | High |
| Classic | ~5ms | Low | Low |
| Auto | ~20ms | Medium | Medium |
| Dynamic | ~25ms | High | High |
| iPhone | ~3ms | Low | Low |

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
    layout: LayoutConfiguration(layoutType: .dynamic)
)

// For mobile apps
let config = MosaicConfiguration(
    layout: LayoutConfiguration(layoutType: .iphone)
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
        layoutType: .dynamic
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
var config = MosaicConfiguration.default
config.updateAspectRatio(new: .square)

// Ultrawide mosaic with dynamic layout
var ultrawideConfig = MosaicConfiguration(
    layout: LayoutConfiguration(
        aspectRatio: .ultrawide,
        layoutType: .dynamic
    )
)
```

## Testing Different Layouts

Compare layouts for the same video:

```swift
let layouts: [LayoutType] = [.custom, .classic, .auto, .dynamic, .iphone]

for layoutType in layouts {
    let config = MosaicConfiguration(
        layout: LayoutConfiguration(layoutType: layoutType)
    )
    
    let outputURL = try await generator.generate(
        from: videoURL,
        config: config,
        outputDirectory: outputDir
    )
    
    print("\(layoutType.rawValue) layout saved to: \(outputURL.lastPathComponent)")
}
```

## See Also

- <doc:Architecture>
- ``LayoutProcessor``
- ``LayoutConfiguration``
- ``LayoutType``
- ``AspectRatio``
