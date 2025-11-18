# Generator Comparison Tests

This test suite compares Metal vs Core Graphics (vImage) mosaic generation performance on macOS.

## Quick Start

### Option 1: Run with Script (Recommended)

```bash
cd /Users/francois/Dev/Packages/MosaicKit/MosaicKit
chmod +x run_comparison_test.sh
./run_comparison_test.sh
```

The script will present options:
1. Large Mosaic (10000px, XS density) - ~5 min
2. Extra Large Mosaic (15000px, XXL density) - ~15 min
3. Multiple Density Comparison (M, XS, XL) - ~20 min
4. All tests - ~40 min

### Option 2: Run Specific Test Directly

```bash
# Large mosaic comparison
swift test --filter GeneratorComparisonTests/testLargeMosaicComparison

# Extra large mosaic comparison
swift test --filter GeneratorComparisonTests/testExtraLargeMosaicComparison

# Multiple density comparison
swift test --filter GeneratorComparisonTests/testMultipleDensityComparison

# All comparison tests
swift test --filter GeneratorComparisonTests
```

## Output Locations

Mosaics are saved to separate directories for easy comparison:

- **Metal outputs:** `/tmp/MosaicKitTests/Metal/`
- **Core Graphics outputs:** `/tmp/MosaicKitTests/CoreGraphics/`

### View Results

```bash
# Open both directories
open /tmp/MosaicKitTests/Metal/
open /tmp/MosaicKitTests/CoreGraphics/

# Or open side-by-side
open /tmp/MosaicKitTests/Metal/ /tmp/MosaicKitTests/CoreGraphics/
```

## What the Test Measures

### Performance Metrics

1. **Generator Creation Time** - How long it takes to initialize the generator
2. **Mosaic Generation Time** - Actual mosaic creation time (main metric)
3. **Total Time** - End-to-end including initialization
4. **Pixels per Second** - Efficiency metric for comparing raw throughput

### Output Metrics

1. **File Size** - HEIF compression efficiency
2. **Dimensions** - Verification that both produce same size
3. **Visual Quality** - Side-by-side comparison (manual inspection)

## Expected Results

### Typical Performance on Apple Silicon (M1/M2/M3):

- **Metal:** ~2-5x faster for large mosaics (>5000px)
- **Core Graphics:** More consistent performance, lower memory usage
- **File sizes:** Should be nearly identical (±1%)

### When Core Graphics Might Be Faster:

- Very small mosaics (<2000px)
- Systems with limited GPU memory
- When GPU is busy with other tasks

## Test Configuration

### Video Source
```
/Volumes/Ext-6TB-2/0002025/11/04/Kristy Black.mp4
```

### Configurations Tested

**Large Mosaic:**
- Width: 10000px
- Density: XS (Extra Small)
- Format: HEIF
- Quality: 0.8

**Extra Large Mosaic:**
- Width: 15000px
- Density: XXL (Extra Extra Large)
- Format: HEIF
- Quality: 0.8

**Multiple Density:**
- Width: 8000px
- Densities: M (Medium), XS (Extra Small), XL (Extra Large)
- Format: HEIF
- Quality: 0.8

## Understanding the Output

### Console Output Example

```
📊 PERFORMANCE COMPARISON RESULTS
────────────────────────────────────────────────────────────────────────────────

⏱️  TIMING:
  Metal:
    • Generator Creation: 0.123s
    • Mosaic Generation:  12.456s
    • Total Time:         12.579s

  Core Graphics:
    • Generator Creation: 0.089s
    • Mosaic Generation:  18.234s
    • Total Time:         18.323s

  ⚡️ Speed Winner: Metal is 31.7% faster

📦 OUTPUT:
  Metal:
    • File Size:     45.23 MB
    • Dimensions:    10000 × 5625
    • File:          _Volumes_Ext-6TB-2_0002025_11_04_Kristy_Black_10000_xs_16:9.heif
    • Location:      /tmp/MosaicKitTests/Metal

  Core Graphics:
    • File Size:     45.67 MB
    • Dimensions:    10000 × 5625
    • File:          _Volumes_Ext-6TB-2_0002025_11_04_Kristy_Black_10000_xs_16:9.heif
    • Location:      /tmp/MosaicKitTests/CoreGraphics

  💾 Size: Metal output is 1.0% smaller

⚙️  EFFICIENCY:
  Metal:         146 million pixels/sec
  Core Graphics: 100 million pixels/sec
```

## Troubleshooting

### Video Not Found

Update the video path in the test:
```swift
let videoPath = "/path/to/your/video.mp4"
```

### Out of Memory

Reduce mosaic size or density:
```swift
let config = MosaicConfiguration(
    width: 5000,  // Smaller
    density: .m,  // Lower density
    // ...
)
```

### Test Timeout

Increase test timeout or run individual tests instead of all tests.

## Customizing Tests

### Add Custom Configurations

Edit `GeneratorComparisonTests.swift` and add:

```swift
func testCustomConfiguration() async throws {
    let config = MosaicConfiguration(
        width: 12000,
        density: .l,
        format: .heif,
        layout: .default,
        includeMetadata: true,
        useAccurateTimestamps: true,
        compressionQuality: 0.9
    )

    // Test both implementations
    let metalResults = try await runGeneratorTest(
        preference: .preferMetal,
        config: config,
        videoURL: videoURL,
        label: "Custom_Metal"
    )

    let cgResults = try await runGeneratorTest(
        preference: .preferCoreGraphics,
        config: config,
        videoURL: videoURL,
        label: "Custom_CG"
    )

    printComparisonResults(metal: metalResults, coreGraphics: cgResults)
}
```

### Test Different Videos

```swift
let videos = [
    "/path/to/video1.mp4",
    "/path/to/video2.mp4",
    "/path/to/video3.mp4"
]

for videoPath in videos {
    // Run comparison for each video
}
```

## Notes

- Tests keep generated mosaics for manual inspection
- To clean up: `rm -rf /tmp/MosaicKitTests/`
- Large tests may take significant time (15-40 minutes)
- GPU thermal throttling may affect Metal performance on sustained workloads
- Core Graphics performance is more consistent across long test runs
