# MosaicKit Documentation Index

Welcome to the MosaicKit documentation! This guide will help you find the right documentation for your needs.

## 📚 Documentation Structure

```
MosaicKit/
├── README.md              # Main documentation (start here!)
├── QUICKSTART.md          # 5-minute tutorial
├── API.md                 # Complete API reference
├── CLAUDE.md              # Developer guide for Claude Code
├── DOCUMENTATION.md       # This file (documentation index)
└── Examples/
    ├── README.md          # Examples overview
    ├── BasicExample.swift
    ├── BatchExample.swift
    └── AdvancedExample.swift
```

## 🚀 Getting Started

### I'm new to MosaicKit
👉 **Start here**: [QUICKSTART.md](QUICKSTART.md)
- 5-minute tutorial
- Simple working example
- Common use cases
- Configuration cheat sheet

### I want comprehensive documentation
👉 **Read**: [README.md](README.md)
- Complete feature overview
- Installation instructions
- Configuration options
- Advanced usage
- Performance tips
- Troubleshooting

### I need API documentation
👉 **Reference**: [API.md](API.md)
- Complete API reference
- All classes, methods, properties
- Parameter descriptions
- Return types and errors
- Code examples

### I want working code examples
👉 **Check out**: [Examples/](Examples/)
- BasicExample.swift - Simple single-video generation
- BatchExample.swift - Process multiple videos
- AdvancedExample.swift - Multiple configurations
- Error handling patterns
- Progress tracking

### I'm using Claude Code
👉 **See**: [CLAUDE.md](CLAUDE.md)
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
- [QUICKSTART.md - Step-by-step](QUICKSTART.md#5-minute-tutorial)
- [Examples/BasicExample.swift](Examples/BasicExample.swift)

### Configuration
- [README.md - Configuration Options](README.md#configuration-options)
- [QUICKSTART.md - Configuration Cheat Sheet](QUICKSTART.md#configuration-cheat-sheet)
- [API.md - MosaicConfiguration](API.md#mosaicconfiguration)

### Batch Processing
- [README.md - Batch Processing](README.md#batch-processing)
- [Examples/BatchExample.swift](Examples/BatchExample.swift)
- [API.md - MosaicGeneratorCoordinator](API.md#mosaicgeneratorcoordinator)

### Advanced Features
- [README.md - Advanced Usage](README.md#advanced-usage)
- [Examples/AdvancedExample.swift](Examples/AdvancedExample.swift)
- Custom layouts
- Progress tracking
- Performance optimization

### Layout Algorithms
- [README.md - Layout Algorithm Details](README.md#layout-algorithm-details)
- Custom, Classic, Auto, Dynamic layouts
- iPhone-optimized layouts

### Error Handling
- [README.md - Error Handling](README.md#error-handling)
- [Examples/AdvancedExample.swift - ErrorHandlingExample](Examples/AdvancedExample.swift)
- [API.md - Errors](API.md#errors)

### Performance
- [README.md - Performance Tips](README.md#performance-tips)
- [README.md - System Requirements](README.md#system-requirements-for-best-performance)
- [README.md - Concurrency Management](README.md#concurrency-management)

### API Reference
- [API.md - Core Classes](API.md#core-classes)
- [API.md - Models](API.md#models)
- [API.md - Configuration](API.md#configuration)

## 🎯 Common Tasks

### "I want to generate a single mosaic"
1. Read [QUICKSTART.md](QUICKSTART.md)
2. Run [Examples/BasicExample.swift](Examples/BasicExample.swift)
3. Customize configuration from [README.md](README.md#configuration-options)

### "I need to process multiple videos"
1. Check [README.md - Batch Processing](README.md#batch-processing)
2. Study [Examples/BatchExample.swift](Examples/BatchExample.swift)
3. Reference [API.md - MosaicGeneratorCoordinator](API.md#mosaicgeneratorcoordinator)

### "I want to customize the layout"
1. See [README.md - Layout Options](README.md#layout-options)
2. Review [README.md - Layout Algorithm Details](README.md#layout-algorithm-details)
3. Check [Examples/AdvancedExample.swift - Custom Layout](Examples/AdvancedExample.swift)

### "I need to optimize performance"
1. Read [README.md - Performance Tips](README.md#performance-tips)
2. Check [README.md - System Requirements](README.md#system-requirements-for-best-performance)
3. Review [QUICKSTART.md - Pro Tips](QUICKSTART.md#pro-tips)

### "I'm getting errors"
1. Check [README.md - Error Handling](README.md#error-handling)
2. Review [README.md - Troubleshooting](README.md#troubleshooting)
3. See [Examples/AdvancedExample.swift - Error Handling](Examples/AdvancedExample.swift)

### "I need the API details"
1. Go to [API.md](API.md)
2. Use the Table of Contents to find specific APIs
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

1. **Start with QUICKSTART.md** if you're new
2. **Reference README.md** for comprehensive information
3. **Use API.md** when you need exact method signatures
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
**Documentation Version**: 1.1.4
**Package Version**: 1.1.4

---

Need help? Start with [QUICKSTART.md](QUICKSTART.md) 🚀
