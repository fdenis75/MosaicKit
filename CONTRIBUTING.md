# Contributing to MosaicKit

Thank you for your interest in contributing to MosaicKit! This document provides guidelines and instructions for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Testing Guidelines](#testing-guidelines)
- [Code Style](#code-style)
- [Pull Request Process](#pull-request-process)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment for all contributors.

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork locally
3. Create a new branch for your changes
4. Make your changes
5. Test thoroughly
6. Submit a pull request

## Development Setup

### Requirements

- macOS 26.0+ or iOS 26.0+
- Xcode 16.0+
- Swift 6.2+
- Metal-capable device (for macOS testing)

### Building the Package

```bash
# Clone the repository
git clone https://github.com/[YOUR-USERNAME]/MosaicKit.git
cd MosaicKit

# Build the package
swift build

# Run tests
swift test

# Build documentation
swift package generate-documentation
```

### Platform-Specific Testing

MosaicKit has two platform-specific implementations:

- **macOS**: Metal GPU acceleration (`MetalMosaicGenerator`)
- **iOS**: Core Graphics with vImage/Accelerate (`CoreGraphicsMosaicGenerator`)

When testing, ensure changes work on both platforms:

```bash
# Test on macOS
swift test

# Test on iOS Simulator
xcodebuild test -scheme MosaicKit -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Making Changes

### Branch Naming

Use descriptive branch names:
- `feature/add-new-layout-algorithm`
- `fix/thumbnail-extraction-crash`
- `docs/improve-api-documentation`
- `test/add-layout-processor-tests`

### Commit Messages

Write clear, concise commit messages:

```
Add dynamic layout algorithm for adaptive mosaics

- Implement center-emphasized thumbnail sizing
- Add layout caching for performance
- Update documentation with new layout type
- Add unit tests for dynamic layout calculation
```

## Testing Guidelines

### Test Structure

MosaicKit uses a combination of testing frameworks:
- **XCTest** for unit and integration tests
- **Swift Testing** (modern approach) for new tests

### Writing Tests

1. **Unit Tests**: Test individual components in isolation
   ```swift
   @Test func testLayoutCalculation() {
       let processor = LayoutProcessor()
       let layout = processor.calculateLayout(...)
       #expect(layout.thumbCount > 0)
   }
   ```

2. **Integration Tests**: Test end-to-end workflows
   ```swift
   func testMosaicGeneration() async throws {
       let generator = try MosaicGenerator()
       let url = try await generator.generate(...)
       XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
   }
   ```

3. **Platform-Specific Tests**: Test both Metal and Core Graphics
   ```swift
   func testMetalVsCoreGraphics() async throws {
       let metalGen = try MosaicGenerator(preference: .preferMetal)
       let cgGen = try MosaicGenerator(preference: .preferCoreGraphics)
       // Compare results...
   }
   ```

### Running Tests

```bash
# Run all tests
swift test

# Run specific test
swift test --filter LayoutProcessorTests

# Run with code coverage
swift test --enable-code-coverage

# Generate coverage report
xcrun llvm-cov report .build/debug/MosaicKitPackageTests.xctest/Contents/MacOS/MosaicKitPackageTests \
  -instr-profile .build/debug/codecov/default.profdata
```

### Test Coverage

- Aim for 60%+ code coverage
- All new features must include tests
- Critical path components (layout algorithms, frame extraction) require comprehensive testing

## Code Style

### Swift Style Guidelines

MosaicKit follows Swift 6 best practices:

1. **Swift Concurrency**: Use async/await and actors
   ```swift
   public actor MetalMosaicGenerator {
       public func generate(...) async throws -> URL {
           // Implementation
       }
   }
   ```

2. **Error Handling**: Use proper error propagation (avoid `try!`)
   ```swift
   // Good
   let generator = try MosaicGeneratorFactory.createGenerator(preference: preference)

   // Bad
   let generator = try! MosaicGeneratorFactory.createGenerator(preference: preference)
   ```

3. **Sendable Conformance**: Ensure thread-safe types
   ```swift
   public struct MosaicConfiguration: Sendable {
       // All stored properties must be Sendable
   }
   ```

4. **Platform-Specific Code**: Use conditional compilation
   ```swift
   #if os(macOS)
   import Metal
   // macOS-specific code
   #elseif os(iOS)
   import Accelerate
   // iOS-specific code
   #endif
   ```

5. **Documentation**: Use DocC-style comments
   ```swift
   /// Calculates optimal mosaic layout
   /// - Parameters:
   ///   - thumbnailCount: Number of thumbnails to arrange
   ///   - aspectRatio: Target aspect ratio for the mosaic
   /// - Returns: Optimal layout configuration
   public func calculateLayout(...) -> MosaicLayout {
       // Implementation
   }
   ```

### Code Formatting

- Use 4 spaces for indentation (no tabs)
- Maximum line length: 120 characters
- Follow Swift API Design Guidelines
- Use meaningful variable and function names

## Pull Request Process

### Before Submitting

1. ✅ All tests pass (`swift test`)
2. ✅ Code builds without warnings (`swift build`)
3. ✅ New features include tests
4. ✅ Documentation is updated
5. ✅ Commit history is clean

### Submitting a Pull Request

1. Push your branch to your fork
2. Open a pull request against `main`
3. Fill out the PR template completely
4. Link any related issues
5. Request review from maintainers

### PR Title Format

```
[Type] Brief description

Examples:
[Feature] Add iPhone-optimized layout algorithm
[Fix] Resolve Metal GPU timeout for large mosaics
[Docs] Update API documentation for MosaicGenerator
[Test] Add comprehensive LayoutProcessor tests
```

### PR Description Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update
- [ ] Performance improvement

## Testing
Describe how you tested these changes

## Checklist
- [ ] Tests pass locally
- [ ] Added/updated tests
- [ ] Updated documentation
- [ ] No breaking changes (or documented)
- [ ] Tested on both macOS and iOS (if applicable)

## Screenshots (if applicable)
Add screenshots for UI changes
```

## Reporting Bugs

### Before Reporting

1. Check existing issues for duplicates
2. Verify the bug exists in the latest version
3. Collect relevant information (logs, crash reports, environment)

### Bug Report Template

```markdown
**Describe the Bug**
Clear and concise description

**To Reproduce**
Steps to reproduce:
1. Create MosaicGenerator with config...
2. Call generate() with video...
3. See error

**Expected Behavior**
What you expected to happen

**Actual Behavior**
What actually happened

**Environment**
- macOS/iOS version:
- Swift version:
- MosaicKit version:
- Metal availability (macOS only):

**Logs/Crash Reports**
Attach relevant logs or crash reports

**Additional Context**
Any other context about the problem
```

## Requesting Features

### Feature Request Template

```markdown
**Is your feature request related to a problem?**
Clear description of the problem

**Describe the Solution**
What you want to happen

**Describe Alternatives**
Alternative solutions you've considered

**Additional Context**
Mockups, examples, or other context

**Platform Considerations**
Does this apply to:
- [ ] macOS (Metal)
- [ ] iOS (Core Graphics)
- [ ] Both platforms
```

## Platform-Specific Considerations

### Metal (macOS)

- Test with different GPU configurations
- Ensure GPU timeout handling (batch processing)
- Verify texture management and memory usage
- Test with large mosaics (15000+ pixels)

### Core Graphics (iOS)

- Test on multiple device sizes
- Verify vImage buffer pool management
- Test memory pressure scenarios
- Ensure efficient battery usage

## Questions?

- Open a GitHub Discussion for general questions
- Use GitHub Issues for bug reports and feature requests
- Check existing documentation in `/docs` and DocC catalog

Thank you for contributing to MosaicKit!
