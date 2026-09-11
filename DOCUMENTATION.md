# MosaicKit Documentation Index

Welcome to the MosaicKit documentation! This guide will help you find the right documentation for your needs.

## 📚 Documentation Structure

```
MosaicKit/
├── README.md                    # Main documentation (start here!)
├── CLAUDE.md / AGENTS.md        # Developer guide for AI coding assistants
├── CONTRIBUTING.md              # Contribution guidelines
├── MosaicKit-DeepDive.md        # Detailed architecture & structural breakdown
├── DOCUMENTATION.md             # This file (documentation index)
├── Sources/MosaicKit.docc/      # DocC catalog (API reference + guides)
│   ├── GettingStarted.md
│   ├── Articles/QuickStart.md
│   ├── Articles/Architecture.md
│   ├── Articles/LayoutAlgorithms.md
│   ├── Articles/PerformanceGuide.md
│   ├── Articles/PlatformStrategy.md
│   ├── Articles/PreviewExporting.md
│   └── Articles/BackgroundProcessing.md
└── Examples/
    ├── README.md                # Examples overview
    ├── SimpleExample.swift
    ├── BasicExample.swift
    ├── BatchExample.swift
    ├── AdvancedExample.swift
    └── PreviewCompositionExample.swift
```

Build the DocC catalog into browsable API documentation with `swift package generate-documentation`.

## 🚀 Getting Started

### I'm new to MosaicKit
👉 **Start here**: <doc:GettingStarted> and <doc:QuickStart> in the DocC catalog
- Installation and platform requirements
- Your first mosaic in a few lines of code
- Configuration basics

### I want comprehensive documentation
👉 **Read**: [README.md](README.md)
- Complete feature overview
- Installation instructions
- Configuration options
- Advanced usage
- Performance tips
- Troubleshooting

### I need API documentation
👉 **Reference**: the DocC catalog at `Sources/MosaicKit.docc/`
- Build it with `swift package generate-documentation`, or browse the `.md` sources directly
- Every public type, method, and property is documented in Sources/ doc comments and surfaced there

### I want working code examples
👉 **Check out**: [Examples/](Examples/)
- `SimpleExample.swift` - Minimal single-video generation
- `BasicExample.swift` - Single-video generation with configuration
- `BatchExample.swift` - Process multiple videos
- `AdvancedExample.swift` - Multiple configurations
- `PreviewCompositionExample.swift` - Preview video / `AVPlayerItem` composition
- Error handling patterns
- Progress tracking

### I'm using an AI coding assistant
👉 **See**: [CLAUDE.md](CLAUDE.md) (also mirrored as [AGENTS.md](AGENTS.md))
- Build and test commands
- Architecture overview
- Development guidelines
- Technical details

## 📖 Documentation by Topic

### Installation
- [README.md - Installation](README.md#installation)
- Swift Package Manager setup
- Xcode integration

### Basic Usage
- DocC `Articles/QuickStart.md` - Step-by-step tutorial
- [Examples/BasicExample.swift](Examples/BasicExample.swift)

### Configuration
- [README.md - Configuration Options](README.md#configuration-options)
- DocC `GettingStarted.md` and `Articles/QuickStart.md`
- DocC catalog - `MosaicConfiguration` reference (from doc comments in `Sources/Models/MosaicConfiguration.swift`)

### Batch Processing
- [README.md - Batch Processing](README.md#batch-processing)
- [Examples/BatchExample.swift](Examples/BatchExample.swift)
- DocC catalog - `MosaicGeneratorCoordinator` reference

### Advanced Features
- [README.md - Advanced Usage](README.md#advanced-usage)
- [Examples/AdvancedExample.swift](Examples/AdvancedExample.swift)
- Custom layouts
- Progress tracking
- Performance optimization

### Layout Algorithms
- [README.md - Layout Algorithm Details](README.md#layout-algorithm-details)
- DocC `Articles/LayoutAlgorithms.md`
- Custom, Classic, Auto, Dynamic layouts
- iPhone-optimized layouts

### Error Handling
- [README.md - Error Handling](README.md#error-handling)
- [Examples/AdvancedExample.swift](Examples/AdvancedExample.swift)
- DocC catalog - `MosaicError`, `PreviewError`, `VideoError`, `MetalProcessorError` reference

### Performance
- [README.md - Performance Tips](README.md#performance-tips)
- [README.md - System Requirements](README.md#system-requirements-for-best-performance)
- [README.md - Concurrency Management](README.md#concurrency-management)
- DocC `Articles/PerformanceGuide.md`

### Background Processing (iOS)
- DocC `Articles/BackgroundProcessing.md` - wrapping generation in `BGContinuedProcessingTask`

### API Reference
- The DocC catalog at `Sources/MosaicKit.docc/` (build with `swift package generate-documentation`)
- Doc comments on every public type in `Sources/`

## 🎯 Common Tasks

### "I want to generate a single mosaic"
1. Read DocC `Articles/QuickStart.md`
2. Run [Examples/BasicExample.swift](Examples/BasicExample.swift)
3. Customize configuration from [README.md](README.md#configuration-options)

### "I need to process multiple videos"
1. Check [README.md - Batch Processing](README.md#batch-processing)
2. Study [Examples/BatchExample.swift](Examples/BatchExample.swift)
3. Reference the `MosaicGeneratorCoordinator` doc comments in `Sources/Processing/MosaicGeneratorCoordinator.swift`

### "I want to customize the layout"
1. See [README.md - Layout Options](README.md#layout-options)
2. Review [README.md - Layout Algorithm Details](README.md#layout-algorithm-details) and DocC `Articles/LayoutAlgorithms.md`
3. Check [Examples/AdvancedExample.swift](Examples/AdvancedExample.swift)

### "I need to optimize performance"
1. Read [README.md - Performance Tips](README.md#performance-tips) and DocC `Articles/PerformanceGuide.md`
2. Check [README.md - System Requirements](README.md#system-requirements-for-best-performance)

### "I'm getting errors"
1. Check [README.md - Error Handling](README.md#error-handling)
2. Review [README.md - Troubleshooting](README.md#troubleshooting)
3. See [Examples/AdvancedExample.swift](Examples/AdvancedExample.swift)

### "I need the API details"
1. Build the DocC catalog with `swift package generate-documentation`, or browse `Sources/MosaicKit.docc/`
2. Use the doc comments on public types in `Sources/` as the source of truth
3. Reference code examples in [Examples/](Examples/)

## 📋 Quick Reference

### Configuration Quick Reference

```swift
// Quick preview
config.width = 2000
config.density = .xl
config.format = .jpeg

// Balanced (default)
config.width = 5000
config.density = .m
config.format = .heif

// High quality
config.width = 8000
config.density = .xs
config.format = .heif
config.compressionQuality = 0.6
```

### Density Levels

| Level | Factor | Use Case |
|-------|--------|----------|
| `.xxl` | 0.25x | Ultra-fast |
| `.xl` | 0.5x | Fast preview |
| `.l` | 0.75x | Preview |
| `.m` | 1.0x | Balanced (default) |
| `.s` | 2.0x | Detailed |
| `.xs` | 3.0x | Very detailed |
| `.xxs` | 4.0x | Maximum detail |

### Output Formats

| Format | Extension | Pros | Recommended For |
|--------|-----------|------|-----------------|
| `.heif` | .heic | Best compression | Most cases |
| `.jpeg` | .jpg | Universal | Sharing |
| `.png` | .png | Lossless | Quality critical |
| `.webp` | .webp | Web-compatible compression | Requires linking `MosaicKitWebP` + calling `MosaicKitWebP.register()` |

### Aspect Ratios

| Type | Ratio | Use Case |
|------|-------|----------|
| `.widescreen` | 16:9 | Desktop, TV |
| `.standard` | 4:3 | Traditional |
| `.square` | 1:1 | Social media |
| `.ultrawide` | 21:9 | Cinematic |
| `.vertical` | 9:16 | Mobile, Stories |

## 🔗 External Resources

- [Swift Package Manager Documentation](https://swift.org/package-manager/)
- [Metal Documentation](https://developer.apple.com/metal/)
- [AVFoundation Documentation](https://developer.apple.com/av-foundation/)

## 💡 Tips for Reading Documentation

1. **Start with the DocC `QuickStart` article** if you're new
2. **Reference README.md** for comprehensive information
3. **Build the DocC catalog** when you need exact method signatures
4. **Run Examples** to see working code
5. **Search this file** (DOCUMENTATION.md) to find specific topics

## 🆘 Getting Help

1. **Documentation**: Check relevant sections above
2. **Examples**: Review working code in Examples/
3. **Issues**: Open a GitHub issue
4. **Discussions**: Join GitHub discussions

## 📝 Documentation Versions

- **Latest**: Current documentation
- **Stable**: Matches latest release
- **Development**: Main branch documentation

Always refer to the documentation version matching your installed package version.

## ✨ Contributing to Documentation

Found an error or want to improve the docs?

1. Documentation files are written in Markdown
2. Examples should be runnable and tested
3. API docs should match actual implementation
4. Follow existing documentation style

## 📄 License

MosaicKit is available under the MIT License. See the LICENSE file for details.

---

**Last Updated**: 2026
**Documentation Version**: 1.6.4
**Package Version**: 1.6.4

---

Need help? Start with the DocC `QuickStart` article in `Sources/MosaicKit.docc/Articles/` 🚀
