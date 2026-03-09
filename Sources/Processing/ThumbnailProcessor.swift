import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import OSLog
import Vision
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif


/// A processor for extracting and managing video thumbnails
// @available(macOS 26, iOS 26, *)
public final class ThumbnailProcessor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.mosaicKit", category: "thumbnail-processor")
    private let config: MosaicConfiguration
    public let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "thumbnail-processor")

    /// Initialize a new thumbnail processor
    /// - Parameter config: Configuration for thumbnail processing
    public init(config: MosaicConfiguration) {
        self.config = config
    }
    
    /// Extract thumbnails from video with timestamps
    /// - Parameters:
    ///   - file: Video file URL
    ///   - layout: Layout information for the mosaic
    ///   - asset: Video asset to extract thumbnails from
    ///   - preview: Whether generating preview thumbnails
    ///   - accurate: Whether to use accurate timestamp extraction
    /// - Returns: Array of tuples containing thumbnail images and their timestamps
    public func extractThumbnails(
        from file: URL,
        layout: MosaicLayout,
        asset: AVAsset,
        preview: Bool = false,
        accurate: Bool = false,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> [(image: CGImage, timestamp: String)] {
        let state = signposter.beginInterval("Extract Thumbnails")
        defer { signposter.endInterval("Extract Thumbnails", state) }
        
        let duration = try await asset.load(.duration).seconds
        let generator = configureGenerator(for: asset, accurate: accurate, preview: preview, layout: layout)

        let times = calculateExtractionTimes(
            duration: duration,
            count: layout.positions.count
        )
        
        var thumbnails: [Int: (CGImage, String)] = [:] // Use dictionary to track by index
        var failedIndices: [Int] = []
        var extractedFrames: [(index: Int, image: CGImage, timestamp: String)] = []

        // First pass: Extract all frames sequentially (AVAssetImageGenerator is not thread-safe)
        // but process timestamps in parallel afterward
        var currentIndex = 0
        for await result in generator.images(for: times) {
            let index = currentIndex
            currentIndex += 1
            progressHandler?(Double(currentIndex) / Double(times.count) * 0.6)
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                let timestamp = self.formatTimestamp(seconds: actual.seconds)
                extractedFrames.append((index: index, image: image, timestamp: timestamp))
            case .failure(requestedTime: let requestedTime, error: let error):
                logger.warning("⚠️ Frame extraction failed at \(self.formatTimestamp(seconds: requestedTime.seconds)): \(error.localizedDescription)")
                failedIndices.append(index)
            }

            // Report progress
           
        }

        // Process extracted frames in parallel (add timestamps)
        await withTaskGroup(of: (Int, CGImage, String).self) { group in
            for frame in extractedFrames {
                let size = layout.thumbnailSizes[frame.index]
                group.addTask { [self] in
                    let imageWithTimestamp = self.addTimestampToImage(image: frame.image, timestamp: frame.timestamp, size: size)
                    return (frame.index, imageWithTimestamp, frame.timestamp)
                }
            }

            for await (index, image, timestamp) in group {
                thumbnails[index] = (image, timestamp)
                // Report progress
                let calculatedProgress = 0.6 + (Double(thumbnails.count) / Double(times.count)) * 0.4
                progressHandler?(calculatedProgress)
            }
        }

        // Retry failed extractions once
        var stillFailed: [Int] = []
        if !failedIndices.isEmpty {
            logger.debug("🔄 Retrying \(failedIndices.count) failed extractions...")
            let failedTimes = failedIndices.map { times[$0] }
            var retryIndex = 0
            var retriedFrames: [(index: Int, image: CGImage, timestamp: String)] = []

            for await result in generator.images(for: failedTimes) {
                let originalIndex = failedIndices[retryIndex]
                retryIndex += 1

                switch result {
                case .success(requestedTime: _, image: let image, actualTime: let actual):
                    let timestamp = self.formatTimestamp(seconds: actual.seconds)
                    retriedFrames.append((index: originalIndex, image: image, timestamp: timestamp))
                    logger.debug("✅ Retry successful for frame \(originalIndex)")
                case .failure(requestedTime: let requestedTime, error: let error):
                    logger.error("❌ Retry failed for frame \(originalIndex) at \(self.formatTimestamp(seconds: requestedTime.seconds)): \(error.localizedDescription)")
                    stillFailed.append(originalIndex)
                }
            }

            // Process retried frames in parallel
            await withTaskGroup(of: (Int, CGImage, String).self) { group in
                for frame in retriedFrames {
                    let size = layout.thumbnailSizes[frame.index]
                    group.addTask { [self] in
                        let imageWithTimestamp = self.addTimestampToImage(image: frame.image, timestamp: frame.timestamp, size: size)
                        return (frame.index, imageWithTimestamp, frame.timestamp)
                    }
                }

                for await (index, image, timestamp) in group {
                    thumbnails[index] = (image, timestamp)
                }
            }

            // Use blank images for frames that failed twice
            for index in stillFailed {
                if let blankImage = createBlankImage(size: layout.thumbnailSizes[index]) {
                    thumbnails[index] = (blankImage, "00:00:00")
                    logger.debug("⚠️ Using blank image for frame \(index) after retry failure")
                }
            }

            let successfulRetries = failedIndices.count - stillFailed.count
            if successfulRetries > 0 {
                logger.debug("✅ Successfully recovered \(successfulRetries) frames on retry")
            }
            if !stillFailed.isEmpty {
                logger.warning("⚠️ \(stillFailed.count) frames still failed after retry, using blank images")
            }
        }

        // Check if we have any valid thumbnails
        if thumbnails.isEmpty {
            logger.error("❌ All extractions failed")
            throw MosaicError.generationFailed(NSError(
                domain: "com.mosaicKit",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract any thumbnails"]
            ))
        }
        
        let successCount = thumbnails.count
        let totalExpected = times.count
        logger.debug("✅ \(file.lastPathComponent) - Thumbnail extraction complete - Success: \(successCount)/\(totalExpected)")
        progressHandler?(1.0)
        // Convert dictionary back to sorted array
        return (0..<totalExpected).compactMap { index in
            thumbnails[index]
        }
    }
    
    /// Extract thumbnails from video with timestamps as an async stream
    /// - Parameters:
    ///   - file: Video file URL
    ///   - layout: Layout information for the mosaic
    ///   - asset: Video asset to extract thumbnails from
    ///   - accurate: Whether to use accurate timestamp extraction
    /// - Returns: Async stream of tuples containing index, thumbnail image and timestamp
    public func extractFramesStream(
        from file: URL,
        layout: MosaicLayout,
        asset: AVAsset,
        accurate: Bool = false
    ) -> AsyncThrowingStream<(index: Int, image: CGImage, timestamp: String), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Create local asset to avoid capturing non-Sendable AVAsset
                    let localAsset = AVURLAsset(url: file)
                    let duration = try await localAsset.load(.duration).seconds
                    let generator = configureGenerator(for: localAsset, accurate: accurate, preview: false, layout: layout)
                    let times = calculateExtractionTimes(duration: duration, count: layout.positions.count)
                    
                    var currentIndex = 0
                    for await result in generator.images(for: times) {
                        let index = currentIndex
                        currentIndex += 1
                        
                        switch result {
                        case .success(_, let image, let actualTime):
                             let timestamp = formatTimestamp(seconds: actualTime.seconds)
                             continuation.yield((index, image, timestamp))
                        case .failure(let requestedTime, let error):
                            logger.warning("⚠️ Frame extraction failed at \(requestedTime.seconds): \(error.localizedDescription)")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Extract thumbnails from video with timestamps
    /// - Parameters:
    ///   - file: Video file URL
    ///   - count: Number of thumbnails to extract
    ///   - size: Size of each thumbnail
    ///   - asset: Video asset to extract thumbnails from
    ///   - accurate: Whether to use accurate timestamp extraction
    /// - Returns: Array of tuples containing thumbnail images and their timestamps
    public func extractThumbnailsUI(
        from file: URL,
        count: Int,
        size: CGSize,
        asset: AVAsset,
        accurate: Bool = true
    ) async throws -> [(image: CGImage, timestamp: String)] {
        let duration = try await asset.load(.duration).seconds
        let generator = configureGenerator(for: asset, accurate: accurate, preview: false, layout: .init(rows: 1, cols: 1, thumbnailSize: size, positions: [(x: 0, y: 0)], thumbCount: count, thumbnailSizes: [size], mosaicSize: size))
        
        // Calculate evenly spaced times
        let interval = duration / Double(count + 1)
        let times = (1...count).map { i in
            CMTime(seconds: interval * Double(i), preferredTimescale: 600)
        }
        
        var thumbnails: [(Int, CGImage, String)] = []
        
        for await result in generator.images(for: times) {
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                let timestamp = formatTimestamp(seconds: actual.seconds)
                let imageWithTimestamp = addTimestampToImage(image: image, timestamp: timestamp, size: size)
                thumbnails.append((thumbnails.count, imageWithTimestamp, timestamp))
            case .failure:
                if let blankImage = createBlankImage(size: size) {
                    thumbnails.append((thumbnails.count, blankImage, "00:00:00"))
                }
            }
        }
        
        return thumbnails
            .sorted { $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }
    

    
    /// Generate mosaic from extracted frames (CoreGraphics fallback version)
    /// - Parameters:
    ///   - frames: Array of frames with timestamps
    ///   - layout: Layout information
    ///   - metadata: Video metadata
    ///   - config: Mosaic configuration
    /// - Returns: Generated mosaic image
    public func generateMosaic(
        from frames: [(image: CGImage, timestamp: String)],
        layout: MosaicLayout,
        metadata: VideoMetadata,
        config: MosaicConfiguration,
        metadataHeader: CGImage? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }
        
        logger.debug("🎨 Starting mosaic generation - Frames: \(frames.count)")
        
        // Create a new image context
        let hasMetadata = config.includeMetadata && metadataHeader != nil
        let metadataHeight = hasMetadata ? metadataHeader!.height : 0
        let outerPadding = mosaicOuterPadding(for: layout)
        
        // Calculate final mosaic size
        let contentSize = layout.mosaicSize
        var mosaicSize = CGSize(
            width: contentSize.width + (outerPadding * 2),
            height: contentSize.height + (outerPadding * 2)
        )
        if hasMetadata {
            mosaicSize.height += CGFloat(metadataHeight)
        }
        
        // Create bitmap context
        guard let context = CGContext(
            data: nil,
            width: Int(mosaicSize.width),
            height: Int(mosaicSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MosaicError.generationFailed(CancellationError())
        }
        
        // Fill background
        context.setFillColor(CGColor(gray: 0.1, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: mosaicSize))
        
        // Draw metadata header if present
        if hasMetadata, let headerImage = metadataHeader {
            progressHandler?(0.1)
            let yPos = mosaicSize.height - outerPadding - CGFloat(metadataHeight)
            context.draw(
                headerImage,
                in: CGRect(
                    x: outerPadding,
                    y: yPos,
                    width: contentSize.width,
                    height: CGFloat(metadataHeight)
                )
            )
        }
        
        // Draw thumbnails
        let totalFrames = frames.count
        for (index, frame) in frames.enumerated() {
            guard index < layout.positions.count else { break }
            
            // Get original position
            let position = layout.positions[index]
            let size = layout.thumbnailSizes[index]
            
            // Create adjusted position with offset for metadata header if needed
            let yOffset = hasMetadata ? metadataHeight : 0
            
            // Calculate Y position for Core Graphics (bottom-left origin)
            // We want (0,0) of the layout to be at the top-left of the image (below metadata)
            // So y = mosaicHeight - (layoutY + height + offset)
            // Wait, layout.positions.y starts at 0 for top row.
            // So top row y=0.
            // In CG: y = mosaicHeight - (0 + size.height) - metadataHeight if metadata is at top.
            // Let's verify:
            // If metadata is at top (height=100), mosaicHeight=1000.
            // Header drawn at y = 900.
            // First row item (y=0, h=200).
            // Should be drawn below header. Top of item at 900, bottom at 700.
            // CG draw rect origin is bottom-left of the rect.
            // So y = 900 - 200 = 700.
            // Formula: mosaicHeight - (position.y + size.height) - (hasMetadata ? metadataHeight : 0)
            // Wait, if metadata is at top, we shift everything down by metadataHeight.
            // So visual Y (from top) = position.y + metadataHeight.
            // CG Y = mosaicHeight - (visualY + size.height)
            //      = mosaicHeight - (position.y + metadataHeight + size.height)
            
            let visualY = outerPadding + CGFloat(position.y) + CGFloat(yOffset)
            let cgY = mosaicSize.height - visualY - size.height
            
            // CGRect works on both platforms
            let rect = CGRect(
                x: outerPadding + CGFloat(position.x),
                y: cgY, 
                width: size.width, 
                height: size.height
            )
            
            // Apply visual effects
            #if canImport(AppKit)
            if config.layout.visual.addShadow, let shadowSettings = config.layout.visual.shadowSettings {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(shadowSettings.opacity)
                shadow.shadowOffset = shadowSettings.offset
                shadow.shadowBlurRadius = shadowSettings.radius
                shadow.set()
            }
            
            // Draw the thumbnail
            NSImage(cgImage: frame.image, size: size).draw(in: rect)
            #elseif canImport(UIKit)
            // For iOS, we need to handle drawing with shadow using Core Graphics
            if config.layout.visual.addShadow, let shadowSettings = config.layout.visual.shadowSettings {
                // Save the graphics state
                context.saveGState()
                
                // Set up shadow
                context.setShadow(
                    offset: shadowSettings.offset,
                    blur: shadowSettings.radius,
                    color: UIColor.black.withAlphaComponent(shadowSettings.opacity).cgColor
                )
                
                // Draw the image with shadow
                context.draw(frame.image, in: rect)
                
                // Restore graphics state
                context.restoreGState()
            } else {
                // Draw without shadow
                context.draw(frame.image, in: rect)
            }
            #endif
            
            // Update progress
            let progress = 0.2 + (0.7 * Double(index + 1) / Double(totalFrames))
            progressHandler?(progress)
            
            if Task.isCancelled {
                logger.warning("❌ Mosaic creation cancelled")
                throw MosaicError.generationFailed(CancellationError())
            }
        }
        
        // Get the resulting image
        progressHandler?(0.9)
        guard let cgImage = context.makeImage() else {
            throw MosaicError.generationFailed(CancellationError())
        }
        
        let generationTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.debug("✅ Mosaic generation complete - Size: \(cgImage.width)x\(cgImage.height) in \(generationTime) seconds")
        progressHandler?(1.0)
        return cgImage
    }
    
    // MARK: - Private Methods
    
    /// Track performance metrics
    /// - Parameter startTime: The start time of the operation
    private func trackPerformance(startTime: CFAbsoluteTime) {
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.debug("⏱️ Operation completed in \(executionTime) seconds")
    }
    
    private func configureGenerator(
        for asset: AVAsset,
        accurate: Bool,
        preview: Bool,
        layout: MosaicLayout
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        if accurate {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        } else {
            // Use 1 second tolerance for better frame accuracy while maintaining performance
            // Previously was 10 seconds which could select incorrect frames
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        }
        
        if !preview {
            generator.maximumSize = CGSize(
                width: layout.thumbnailSize.width * 2,
                height: layout.thumbnailSize.height * 2
            )
        }
        
        return generator
    }
    
    private func calculateExtractionTimes(duration: Double, count: Int) -> [CMTime] {
        let startPoint = duration * 0.05
        let endPoint = duration * 0.95
        let effectiveDuration = endPoint - startPoint
        
        let firstThirdCount = Int(Double(count) * 0.2)
        let middleCount = Int(Double(count) * 0.6)
        let lastThirdCount = count - firstThirdCount - middleCount
        
        let firstThirdEnd = startPoint + effectiveDuration * 0.33
        let lastThirdStart = startPoint + effectiveDuration * 0.67
        
        let firstThirdStep = (firstThirdEnd - startPoint) / Double(firstThirdCount)
        let middleStep = (lastThirdStart - firstThirdEnd) / Double(middleCount)
        let lastThirdStep = (endPoint - lastThirdStart) / Double(lastThirdCount)
        
        let firstThirdTimes = (0..<firstThirdCount).map { index in
            CMTime(seconds: startPoint + Double(index) * firstThirdStep, preferredTimescale: 600)
        }
        
        let middleTimes = (0..<middleCount).map { index in
            CMTime(seconds: firstThirdEnd + Double(index) * middleStep, preferredTimescale: 600)
        }
        
        let lastThirdTimes = (0..<lastThirdCount).map { index in
            CMTime(seconds: lastThirdStart + Double(index) * lastThirdStep, preferredTimescale: 600)
        }
        
        return firstThirdTimes + middleTimes + lastThirdTimes
    }
    
    private func formatTimestamp(seconds: Double, accurate: Bool = false) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    private func createBlankImage(size: CGSize) -> CGImage? {
        // Use standard RGB color space for blank images
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        #if canImport(AppKit)
        context?.setFillColor(NSColor.clear.cgColor)
        #elseif canImport(UIKit)
        context?.setFillColor(UIColor.clear.cgColor)
        #endif
        
        context?.fill(CGRect(origin: .zero, size: size))
        return context?.makeImage()
    }
    
    /// Creates a metadata header image to be placed at the top of the mosaic
    /// - Parameters:
    ///   - video: The video object containing metadata information
    ///   - width: The width of the mosaic
    ///   - height: Optional height override for the metadata header
    ///   - backgroundColor: Optional background color (if nil, platform-specific default will be used)
    /// - Returns: A CGImage containing the metadata header
    public func createMetadataHeader(
        for video: VideoInput,
        width: Int,
        height: Int? = nil,
        backgroundColor: CGColor? = nil,
        forIphone: Bool = false,
        headerConfig: HeaderConfig = .default,
        swatchColors: [CGColor] = []
    ) -> CGImage? {
        logger.debug("🏷️ Creating metadata header - Width: \(width)")

        // Background colour: config override → caller override → platform default
        let bgColor: CGColor
        if let cfgBg = headerConfig.backgroundColor {
            bgColor = cfgBg.cgColor
        } else if let callerBg = backgroundColor {
            bgColor = callerBg
        } else {
            #if canImport(AppKit)
            bgColor = NSColor(white: 0.1, alpha: 0.25).cgColor
            #elseif canImport(UIKit)
            bgColor = UIColor(white: 0.1, alpha: 0.25).cgColor
            #endif
        }

        let padding: CGFloat = 4.0
        let baseFontSize: CGFloat = forIphone ? 6.0 : 8.0
        let videoAspectRatio = max(0.2, video.aspectRatio ?? 1.0)
        let layoutAspectRatio = max(0.2, Double(config.layout.aspectRatio.ratio))
        let videoVerticality = min(2.0, max(0.6, 1.0 / videoAspectRatio))
        let outputVerticality = min(2.0, max(0.6, 1.0 / layoutAspectRatio))
        let verticalityScale = CGFloat(sqrt(videoVerticality * outputVerticality))
        var fontSize = max(baseFontSize, (CGFloat(width) * 0.01) * verticalityScale)
        // Build ordered rows of text from headerConfig.fields. The file path is
        // always promoted to its own line so it can use a smaller fitted font.
        let textFields = headerConfig.fields.filter {
            if case .colorPalette = $0 { return false }
            return true
        }
        var primaryFieldStrings: [String] = []
        var filePathRowText: String?
        for field in textFields {
            guard let fieldText = formatHeaderField(field, video: video) else { continue }
            if case .filePath = field {
                filePathRowText = fieldText
            } else {
                primaryFieldStrings.append(fieldText)
            }
        }

        var rowSpecs: [HeaderRowSpec] = stride(from: 0, to: primaryFieldStrings.count, by: 3).map { start in
            let end = min(start + 3, primaryFieldStrings.count)
            return HeaderRowSpec(
                text: primaryFieldStrings[start..<end].joined(separator: " | "),
                preferredScale: 1.0,
                minimumScale: 0.75,
                shrinkToFit: false
            )
        }
        if let filePathRowText {
            rowSpecs.append(
                HeaderRowSpec(
                    text: filePathRowText,
                    preferredScale: 0.78,
                    minimumScale: 0.45,
                    shrinkToFit: true
                )
            )
        }
        if rowSpecs.isEmpty {
            rowSpecs = [HeaderRowSpec(text: "", preferredScale: 1.0, minimumScale: 1.0, shrinkToFit: false)]
        }
        let totalPreferredLineScale = rowSpecs.reduce(CGFloat.zero) { $0 + $1.preferredScale }
        
        // Determine header height
        let estimatedLineHeight = fontSize * 1.2
        let calculatedHeight = Int(estimatedLineHeight * totalPreferredLineScale + padding * 4)
        let metadataHeight: Int
        switch headerConfig.height {
        case .auto:    metadataHeight = height ?? calculatedHeight
        case .fixed(let h): metadataHeight = h
        }

        // Clamp font size to fit the available height
        let availableHeight = CGFloat(metadataHeight) - (padding * 4)
        let maxFontByHeight = totalPreferredLineScale > 0 ? availableHeight / (totalPreferredLineScale * 1.5) : fontSize
        fontSize = min(fontSize, maxFontByHeight)
        fontSize = max(baseFontSize, fontSize)

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: metadataHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ Failed to create graphics context for metadata header")
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: metadataHeight))
        drawRoundedHeaderBackground(
            in: context,
            width: CGFloat(width),
            height: CGFloat(metadataHeight),
            color: bgColor
        )

        // Determine text colour: config override → forIphone white → macOS black
        #if canImport(AppKit)
        let defaultTextColor = forIphone ? NSColor.white : NSColor.black
        let textNSColor: NSColor
        if let cfgColor = headerConfig.textColor {
            textNSColor = NSColor(
                red: CGFloat(cfgColor.red), green: CGFloat(cfgColor.green),
                blue: CGFloat(cfgColor.blue), alpha: CGFloat(cfgColor.alpha))
        } else {
            textNSColor = defaultTextColor
        }
        #elseif canImport(UIKit)
        let defaultTextColor = UIColor.black
        let textNSColor: UIColor
        if let cfgColor = headerConfig.textColor {
            textNSColor = UIColor(
                red: CGFloat(cfgColor.red), green: CGFloat(cfgColor.green),
                blue: CGFloat(cfgColor.blue), alpha: CGFloat(cfgColor.alpha))
        } else {
            textNSColor = defaultTextColor
        }
        #endif

        let leftPadding: CGFloat = 20.0
        let rightPadding: CGFloat = 20.0
        let availableTextWidth = max(0, CGFloat(width) - leftPadding - rightPadding)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineSpacing = forIphone ? 1.0 : 2.0

        let rowLayouts = rowSpecs.map {
            makeHeaderRowLayout(
                for: $0,
                textColor: textNSColor,
                paragraphStyle: paragraphStyle,
                baseFontSize: fontSize,
                maxWidth: availableTextWidth
            )
        }
        let rowSpacing = max(4.0, fontSize * (forIphone ? 0.20 : 0.28))
        let totalTextHeight = rowLayouts.reduce(CGFloat.zero) { $0 + $1.metrics.height }
            + (CGFloat(max(0, rowLayouts.count - 1)) * rowSpacing)
        let contentTopInset = padding * 2
        let extraVerticalSpace = max(0, availableHeight - totalTextHeight)
        var currentTopY = CGFloat(metadataHeight) - contentTopInset - (extraVerticalSpace / 2)

        for rowLayout in rowLayouts {
            let yPos = currentTopY - rowLayout.metrics.ascent
            context.saveGState()
            context.textMatrix = CGAffineTransform.identity
            context.textPosition = CGPoint(x: leftPadding, y: yPos)
            CTLineDraw(rowLayout.line, context)
            context.restoreGState()
            currentTopY = yPos - rowLayout.metrics.descent - rowSpacing
        }

        // Colour palette swatches (if requested and colours are available)
        let paletteField = headerConfig.fields.first {
            if case .colorPalette = $0 { return true }; return false
        }
        if let field = paletteField, case .colorPalette(let swatchCount) = field, !swatchColors.isEmpty {
            let n          = min(swatchCount, swatchColors.count)
            let swatchSize = CGFloat(metadataHeight) * 0.25
            let gap: CGFloat = 4
            let totalW     = CGFloat(n) * (swatchSize + gap) - gap
            let startX     = CGFloat(width) - totalW - 20
            let swatchY    = CGFloat(metadataHeight) * 0.1

            for i in 0..<n {
                context.setFillColor(swatchColors[i])
                let r = CGRect(
                    x: startX + CGFloat(i) * (swatchSize + gap),
                    y: swatchY,
                    width: swatchSize, height: swatchSize
                )
                // Draw as circles
                context.fillEllipse(in: r)
            }
        }

        guard let headerImage = context.makeImage() else {
            logger.error("❌ Failed to create metadata header image")
            return nil
        }
        logger.debug("✅ Created metadata header - Size: \(width)×\(metadataHeight)")
        return headerImage
    }

    /// Format a single `MetadataField` to a display string using `VideoInput` data.
    private func formatHeaderField(_ field: MetadataField, video: VideoInput) -> String? {
        switch field {
        case .title:
            return "Title: \(video.title)"
        case .duration:
            guard let d = video.duration, d > 0 else { return nil }
            let h = Int(d) / 3600; let m = (Int(d) % 3600) / 60; let s = Int(d) % 60
            return "Duration: \(String(format: "%02d:%02d:%02d", h, m, s))"
        case .fileSize:
            guard let size = video.fileSize else { return nil }
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useGB, .useMB, .useKB]; fmt.countStyle = .file
            return "Size: \(fmt.string(fromByteCount: size))"
        case .resolution:
            return "Resolution: \(Int(video.width ?? 0))×\(Int(video.height ?? 0))"
        case .codec:
            return "Codec: \(video.metadata.codec ?? "Unknown")"
        case .bitrate:
            return "Bitrate: \(formatBitrate(video.metadata.bitrate))"
        case .frameRate:
            guard let fps = video.frameRate else { return nil }
            return "FPS: \(String(format: "%.2f", fps))"
        case .filePath:
            return "Path: \(video.url.path)"
        case .custom(let label, let value):
            return "\(label): \(value)"
        case .colorPalette:
            return nil  // rendered as swatches, not text
        }
    }
    
    /// Creates a metadata header image to be placed at the top of the mosaic (legacy version)
    /// - Parameters:
    ///   - metadata: The video metadata to display
    ///   - width: The width of the mosaic
    ///   - height: The height of the metadata header (matching first row of thumbnails)
    ///   - backgroundColor: Optional background color (if nil, platform-specific default will be used)
    /// - Returns: A CGImage containing the metadata header
    public func createMetadataHeader(
        metadata: VideoMetadata,
        width: Int,
        height: Int? = nil,
        backgroundColor: CGColor? = nil
    ) -> CGImage? {
        // Set default background color based on platform
        #if canImport(AppKit)
        let bgColor = backgroundColor ?? NSColor(white: 0.1, alpha: 0.25).cgColor
        #elseif canImport(UIKit)
        let bgColor = backgroundColor ?? UIColor(white: 0.1, alpha: 0.25).cgColor
        #endif
        logger.debug("🏷️ Creating metadata header image (legacy version) - Width: \(width)")
        
        // Use provided height or calculate based on width
        let metadataHeight = height ?? Int(round(Double(width) * 0.05))
        let fontSize = max(12.0, CGFloat(metadataHeight) / 3.0)
        
        // Create bitmap context for the header
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: metadataHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ Failed to create graphics context for metadata header")
            return nil
        }
        
        // Create dark semi-transparent background for metadata
        context.setFillColor(bgColor)
        drawRoundedHeaderBackground(
            in: context,
            width: CGFloat(width),
            height: CGFloat(metadataHeight),
            color: bgColor
        )
        
        // Prepare the metadata text
        var metadataItems = [
            "Codec: \(metadata.codec ?? "Unknown")",
            "Bitrate: \(formatBitrate(metadata.bitrate))"
        ]
        
        // Add custom metadata
        let customText = metadata.custom.map { "\($0.key): \($0.value)" }.joined(separator: " | ")
        if !customText.isEmpty {
            metadataItems.append(customText)
        }
        
        let metadataText = metadataItems.joined(separator: " | ")
        
        // Set up text attributes using CoreText
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        #if canImport(AppKit)
        // Create the attributed string
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle
            ]
        #elseif canImport(UIKit)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraphStyle
            ]
        #endif
        
        let attributedString = NSAttributedString(string: metadataText, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        
        // Calculate text width to center it
        let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let textWidth = textBounds.width
        let xPos = (CGFloat(width) - textWidth) / 2
        let yPos = CGFloat(metadataHeight) / 2 + textBounds.height / 4  // Vertically centered
        
        // Draw text
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: xPos, y: yPos)
        CTLineDraw(line, context)
        
        guard let headerImage = context.makeImage() else {
            logger.error("❌ Failed to create metadata header image")
            return nil
        }
        
        logger.debug("✅ Created metadata header - Size: \(width)×\(metadataHeight)")
        return headerImage
    }
    
    // Private helper method to draw metadata directly to a context
    private func drawMetadata(
        context: CGContext,
        metadata: VideoMetadata,
        width: Int,
        height: Int,
        headerHeight: Int? = nil
    ) {
        // Use the provided height or calculate a reasonable size for the header
        let metadataHeight = headerHeight ?? Int(round(Double(height) * 0.2))  // Use 1/5 of total height by default
                                                                              // This will be overridden by the thumbnailHeight in the main method
        let fontSize = max(12.0, CGFloat(metadataHeight) / 3.0)
        
        // Draw a semi-transparent background bar at the top
        context.saveGState()
        
        // First clear the area to ensure transparency
        context.clear(CGRect(x: 0, y: 0, width: width, height: metadataHeight))
        
        // Create dark semi-transparent background for metadata - more transparent to match main method
        #if canImport(AppKit)
        let metadataBackgroundColor = NSColor(white: 0.1, alpha: 0.5).cgColor
        #elseif canImport(UIKit)
        let metadataBackgroundColor = UIColor(white: 0.1, alpha: 0.5).cgColor
        #endif
        context.setFillColor(metadataBackgroundColor)
        drawRoundedHeaderBackground(
            in: context,
            width: CGFloat(width),
            height: CGFloat(metadataHeight),
            color: metadataBackgroundColor
        )
        
        // Prepare the metadata text
        var metadataItems = [
            "Codec: \(metadata.codec ?? "Unknown")",
            "Bitrate: \(formatBitrate(metadata.bitrate))"
        ]
        
        // Add custom metadata
        let customText = metadata.custom.map { "\($0.key): \($0.value)" }.joined(separator: " | ")
        if !customText.isEmpty {
            metadataItems.append(customText)
        }
        
        let metadataText = metadataItems.joined(separator: " | ")
        
        // Set up text attributes using CoreText - matching the main method styling
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let paragraphStyle = NSMutableParagraphStyle()
        // Use left alignment to match the main method
        paragraphStyle.alignment = .left
        
        // Create the attributed string with enhanced visibility against semi-transparent background
        #if canImport(AppKit)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
            .strokeWidth: -0.5, // Text outline for better visibility
            .strokeColor: NSColor.black.withAlphaComponent(0.5)
        ]
        #elseif canImport(UIKit)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle,
            .strokeWidth: -0.5, // Text outline for better visibility
            .strokeColor: UIColor.black.withAlphaComponent(0.5)
        ]
        #endif
        
        let attributedString = NSAttributedString(string: metadataText, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        
        // Left-align text with padding to match main method
        let leftPadding: CGFloat = 20.0
        // Calculate vertical position
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let yPos = CGFloat(metadataHeight) / 2 + bounds.height / 4  // Vertically centered
        
        // Draw text
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: leftPadding, y: yPos)
        CTLineDraw(line, context)
        
        context.restoreGState()
    }
    
    private func formatBitrate(_ bitrate: Int64?) -> String {
        guard let bitrate = bitrate else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bitrate) + "/s"
    }
    
    /// Add timestamp overlay to the thumbnail image with Apple-inspired design
    /// - Parameters:
    ///   - image: The thumbnail image
    ///   - timestamp: The timestamp string to add ("HH:MM:SS")
    ///   - frameIndex: Zero-based index of this frame (used for `.frameIndex` label format)
    ///   - size: The size of the thumbnail
    ///   - labelConfig: Per-frame label configuration (defaults to original appearance)
    /// - Returns: CGImage with label overlay and visual treatment
    internal func addTimestampToImage(
        image: CGImage,
        timestamp: String,
        frameIndex: Int = 0,
        size: CGSize,
        labelConfig: FrameLabelConfig = .default
    ) -> CGImage {
        // Create a context for the image with appropriate scale
        let scale = max(1.0, min(1.2,Double(image.width) / size.width)) // Handle high-resolution images
        // Preserve source color space for accurate color representation
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        // Create a context that supports transparency
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            // Use proper bitmap info for transparency
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            logger.error("❌ Failed to create graphics context for timestamp")
            return image
        }
        
        // Clear the context with transparent background
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Define the image rectangle
        let rect = CGRect(x: 0, y: 0, width: image.width - 2, height: image.height - 2)
        
        // Create rounded corners with a moderate radius (8% of the smallest dimension)
        let cornerRadius = CGFloat(min(image.width, image.height)) * 0.08
        
        // Create a path with rounded corners
        let roundedPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        
        // Save graphics state before clipping
        context.saveGState()

        // Enable antialiasing for smooth rounded corners
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        // Apply the clipping path for the rounded rectangle
        context.beginPath()
        context.addPath(roundedPath)
        context.closePath()
        context.clip()
        
        // Draw the original image with proper alpha channel handling
        context.setBlendMode(.copy)
        context.draw(image, in: rect)
        context.setBlendMode(.normal)
        
        // Restore graphics state after image
        //context.restoreGState()
        
        // Determine label text before the vignette so it is available in all code paths.
        let labelText: String
        switch labelConfig.format {
        case .timestamp:  labelText = timestamp
        case .frameIndex: labelText = "Frame \(frameIndex + 1)"
        case .none:       labelText = ""
        }

        // Add subtle vignette effect for depth (Apple design often uses this)
        // Create gradient for vignette
        let components: [CGFloat] = [
            0.0, 0.0, 0.0, 0.0,   // Transparent at center
            0.0, 0.0, 0.0, 0.35   // Darkened at edges
        ]
        let locations: [CGFloat] = [0.65, 1.0]  // Only affect outer 35% of image
        guard let vignetteGradient = CGGradient(
            colorSpace: colorSpace,
            colorComponents: components,
            locations: locations,
            count: 2
        ) else {
            // Vignette creation failed — restore state and continue with label drawing below.
            context.restoreGState()
            // Fall through: the guard below will handle the no-label early exit.
            guard labelConfig.show, labelConfig.format != .none else {
                guard let visualOnly = context.makeImage() else { return image }
                return visualOnly
            }
            return addTimestampToBaseImage(image: image, timestamp: labelText, size: size, context: context, rect: rect)
        }
        
        // Draw radial gradient from center
        context.drawRadialGradient(
            vignetteGradient,
            startCenter: CGPoint(x: rect.midX, y: rect.midY),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY),
            endRadius: max(CGFloat(image.width), CGFloat(image.height)) * 0.8,
            options: [.drawsAfterEndLocation]
        )
        
        // Restore graphics state after image and vignette
        context.restoreGState()

        // Early exit if no label text is requested; visual treatment (rounded corners,
        // vignette) has already been applied above.
        guard labelConfig.show, labelConfig.format != .none else {
            guard let visualOnly = context.makeImage() else { return image }
            return visualOnly
        }

        let fontSize = overlayFontSize(for: size)

        // Use a system font with bold weight for better readability
        #if canImport(AppKit)
        let systemFont = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        #elseif canImport(UIKit)
        let systemFont = UIFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        #endif

        // Build the platform text colour from the config (defaults to white)
        #if canImport(AppKit)
        let labelColor = NSColor(
            red:   CGFloat(labelConfig.textColor.red),
            green: CGFloat(labelConfig.textColor.green),
            blue:  CGFloat(labelConfig.textColor.blue),
            alpha: CGFloat(labelConfig.textColor.alpha)
        )
        #elseif canImport(UIKit)
        let labelColor = UIColor(
            red:   CGFloat(labelConfig.textColor.red),
            green: CGFloat(labelConfig.textColor.green),
            blue:  CGFloat(labelConfig.textColor.blue),
            alpha: CGFloat(labelConfig.textColor.alpha)
        )
        #endif

        // Apply subtle shadow for better legibility (Apple-style)
        #if canImport(AppKit)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = CGSize(width: 0, height: 1.0 * scale)
        shadow.shadowBlurRadius = 3.0 * scale
        #elseif canImport(UIKit)
        // UIKit uses NSShadow from Foundation, not AppKit
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = CGSize(width: 0, height: 1.0 * scale)
        shadow.shadowBlurRadius = 3.0 * scale
        #endif

        // Create the text attributes with Apple-style refinements
        #if canImport(AppKit)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: systemFont,
            .foregroundColor: labelColor,
            .shadow: shadow
        ]
        #elseif canImport(UIKit)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: systemFont,
            .foregroundColor: labelColor,
            .shadow: shadow
        ]
        #endif

        let attributedString = NSAttributedString(string: labelText, attributes: textAttributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        let textMetrics = textLayoutMetrics(for: line)
        
        // Padding for the pill-shaped background (proportional to font size)
        let paddingX: CGFloat = fontSize * 0.6
        let paddingY: CGFloat = fontSize * 0.3

        // Calculate background rectangle dimensions with more subtle proportions
        let bgWidth  = textMetrics.width  + (paddingX * 2)
        let bgHeight = textMetrics.height + (paddingY * 2)

        // Position based on labelConfig.position
        let hMargin: CGFloat = size.width  * 0.02
        let vMargin: CGFloat = size.height * 0.02
        let bgX: CGFloat
        let bgY: CGFloat
        switch labelConfig.position {
        case .bottomRight:
            bgX = rect.maxX - bgWidth - hMargin
            bgY = rect.maxY - bgHeight - vMargin
        case .bottomLeft:
            bgX = rect.minX + hMargin
            bgY = rect.maxY - bgHeight - vMargin
        case .topRight:
            bgX = rect.maxX - bgWidth - hMargin
            bgY = rect.minY + vMargin
        case .topLeft:
            bgX = rect.minX + hMargin
            bgY = rect.minY + vMargin
        case .center:
            bgX = rect.midX - bgWidth  / 2
            bgY = rect.midY - bgHeight / 2
        }
        
        let bgRect   = CGRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)
        let pillRadius = bgHeight / 2

        // Draw background according to the configured style
        switch labelConfig.backgroundStyle {
        case .none:
            // No background — text only (shadow provides legibility)
            break

        case .fullWidth:
            // Full-width translucent bar at the thumbnail edge nearest the label
            let barY: CGFloat
            switch labelConfig.position {
            case .topLeft, .topRight, .center:
                barY = rect.minY
            default:
                barY = rect.maxY - bgHeight
            }
            let barRect = CGRect(x: rect.minX, y: barY, width: rect.width, height: bgHeight)
            #if canImport(AppKit)
            context.setFillColor(NSColor(white: 0.08, alpha: 0.72).cgColor)
            #elseif canImport(UIKit)
            context.setFillColor(UIColor(white: 0.08, alpha: 0.72).cgColor)
            #endif
            context.fill(barRect)

        case .pill:
            // Apple-style gradient pill (original behaviour)
            #if os(macOS)
            let pillColors = [
                NSColor(white: 0.12, alpha: 0.55).cgColor,
                NSColor(white: 0.08, alpha: 0.75).cgColor
            ]
            #elseif os(iOS)
            let pillColors = [
                UIColor(white: 0.12, alpha: 0.55).cgColor,
                UIColor(white: 0.08, alpha: 0.75).cgColor
            ]
            #endif
            let pillPath = CGPath(
                roundedRect: bgRect,
                cornerWidth: pillRadius, cornerHeight: pillRadius,
                transform: nil
            )
            if let pillGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: pillColors as CFArray,
                locations: [0.0, 1.0]
            ) {
                context.saveGState()
                context.addPath(pillPath)
                context.clip()
                context.drawLinearGradient(
                    pillGradient,
                    start: CGPoint(x: bgRect.midX, y: bgRect.minY),
                    end:   CGPoint(x: bgRect.midX, y: bgRect.maxY),
                    options: []
                )
                context.restoreGState()
                // Subtle border highlight
                #if canImport(AppKit)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
                #elseif canImport(UIKit)
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
                #endif
                context.setLineWidth(0.5 * scale)
                context.addPath(pillPath)
                context.strokePath()
            } else {
                // Fallback to solid fill
                #if canImport(AppKit)
                context.setFillColor(NSColor(white: 0.1, alpha: 0.8).cgColor)
                #elseif canImport(UIKit)
                context.setFillColor(UIColor(white: 0.1, alpha: 0.8).cgColor)
                #endif
                drawPillBackground(in: context, rect: bgRect, radius: pillRadius)
            }
        }

        // Draw the label text centred inside the background rect
        let textX = bgRect.midX - (textMetrics.bounds.width / 2) - textMetrics.bounds.minX
        let baselineY = bgRect.midY - ((textMetrics.ascent - textMetrics.descent) / 2)

        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.textPosition = CGPoint(x: textX, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()

        guard let finalImage = context.makeImage() else {
            logger.error("❌ Failed to create final image with label")
            return image
        }
        return finalImage
    }
    
    /// Helper method to draw timestamp text
    private func drawTimestampText(in context: CGContext, text: String, attributes: [NSAttributedString.Key: Any], rect: CGRect) {
        let nsString = NSString(string: text)
        let stringSize = nsString.size(withAttributes: attributes)
        
        let textX = rect.minX + (rect.width - stringSize.width) / 2
        let textY = rect.minY + (rect.height - stringSize.height) / 2
        
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: textX, y: textY)
        
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        CTLineDraw(line, context)
        context.restoreGState()
    }
    
    /// Helper method to draw pill background
    private func drawPillBackground(in context: CGContext, rect: CGRect, radius: CGFloat) {
        let minX = rect.minX, minY = rect.minY
        let maxX = rect.maxX, maxY = rect.maxY
        
        context.beginPath()
        context.move(to: CGPoint(x: minX + radius, y: minY))
        context.addLine(to: CGPoint(x: maxX - radius, y: minY))
        context.addArc(center: CGPoint(x: maxX - radius, y: minY + radius), 
                      radius: radius, 
                      startAngle: 3 * .pi / 2, 
                      endAngle: 0, 
                      clockwise: false)
        context.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        context.addArc(center: CGPoint(x: maxX - radius, y: maxY - radius), 
                      radius: radius, 
                      startAngle: 0, 
                      endAngle: .pi / 2, 
                      clockwise: false)
        context.addLine(to: CGPoint(x: minX + radius, y: maxY))
        context.addArc(center: CGPoint(x: minX + radius, y: maxY - radius), 
                      radius: radius, 
                      startAngle: .pi / 2, 
                      endAngle: .pi, 
                      clockwise: false)
        context.addLine(to: CGPoint(x: minX, y: minY + radius))
        context.addArc(center: CGPoint(x: minX + radius, y: minY + radius), 
                      radius: radius, 
                      startAngle: .pi, 
                      endAngle: 3 * .pi / 2, 
                      clockwise: false)
        context.closePath()
        context.fillPath()
    }

    private func drawRoundedHeaderBackground(in context: CGContext, width: CGFloat, height: CGFloat, color: CGColor) {
        let inset = max(1.0, min(6.0, height * 0.04))
        let backgroundRect = CGRect(
            x: inset,
            y: inset,
            width: max(0, width - (inset * 2)),
            height: max(0, height - (inset * 2))
        )
        let cornerRadius = min(backgroundRect.height * 0.22, 18.0)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setFillColor(color)
        context.addPath(
            CGPath(
                roundedRect: backgroundRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        )
        context.fillPath()
        context.restoreGState()
    }

    private struct HeaderRowSpec {
        let text: String
        let preferredScale: CGFloat
        let minimumScale: CGFloat
        let shrinkToFit: Bool
    }

    private struct HeaderRowLayout {
        let line: CTLine
        let metrics: TextLineMetrics
    }

    private struct TextLineMetrics {
        let bounds: CGRect
        let width: CGFloat
        let height: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private func overlayFontSize(for size: CGSize) -> CGFloat {
        let referenceDimension = size.width >= size.height ? size.width : size.height
        return max(10.0, min(24.0, referenceDimension * 0.08)) * 1.5
    }

    private func makeHeaderRowLayout(
        for spec: HeaderRowSpec,
        textColor: Any,
        paragraphStyle: NSParagraphStyle,
        baseFontSize: CGFloat,
        maxWidth: CGFloat
    ) -> HeaderRowLayout {
        let minimumFontSize = max(6.0, baseFontSize * spec.minimumScale)
        var currentFontSize = max(minimumFontSize, baseFontSize * spec.preferredScale)
        var line = makeHeaderLine(
            text: spec.text,
            textColor: textColor,
            paragraphStyle: paragraphStyle,
            fontSize: currentFontSize
        )
        var metrics = textLayoutMetrics(for: line)

        while spec.shrinkToFit, metrics.width > maxWidth, currentFontSize > minimumFontSize {
            currentFontSize = max(minimumFontSize, currentFontSize - 0.5)
            line = makeHeaderLine(
                text: spec.text,
                textColor: textColor,
                paragraphStyle: paragraphStyle,
                fontSize: currentFontSize
            )
            metrics = textLayoutMetrics(for: line)
        }

        return HeaderRowLayout(line: line, metrics: metrics)
    }

    private func makeHeaderLine(
        text: String,
        textColor: Any,
        paragraphStyle: NSParagraphStyle,
        fontSize: CGFloat
    ) -> CTLine {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func textLayoutMetrics(for line: CTLine) -> TextLineMetrics {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let width = max(ceil(typographicWidth), ceil(bounds.width))
        let height = ceil(ascent + descent + leading)
        return TextLineMetrics(
            bounds: bounds,
            width: width,
            height: height,
            ascent: ascent,
            descent: descent
        )
    }

    private func mosaicOuterPadding(for layout: MosaicLayout) -> CGFloat {
        let smallestThumbnailDimension = layout.thumbnailSizes
            .map { min($0.width, $0.height) }
            .filter { $0 > 0 }
            .min() ?? min(layout.thumbnailSize.width, layout.thumbnailSize.height)

        return min(24.0, max(8.0, round(smallestThumbnailDimension * 0.04)))
    }
    
    /// Fallback method for adding timestamp to image
    private func addTimestampToBaseImage(image: CGImage, timestamp: String, size: CGSize, context: CGContext, rect: CGRect) -> CGImage {
        // Start fresh with a properly configured context
        let scale = max(1.0, Double(image.width) / size.width)
        // Preserve source color space for accurate color representation
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        
        // Create a new context with proper transparency settings
        guard let newContext = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return image
        }
        
        // Clear context and draw original image with rounded corners
        newContext.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        
        // Create rounded corners
        let cornerRadius = CGFloat(min(image.width, image.height)) * 0.08
        let roundedPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        newContext.saveGState()

        // Enable antialiasing for smooth rounded corners
        newContext.setShouldAntialias(true)
        newContext.setAllowsAntialiasing(true)

        newContext.beginPath()
        newContext.addPath(roundedPath)
        newContext.closePath()
        newContext.clip()
        
        // Draw original image
        newContext.draw(image, in: rect)
        newContext.restoreGState()
        
        let fontSize = overlayFontSize(for: size)
        
        // Create font and attributes
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        #if canImport(AppKit)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowOffset = CGSize(width: 0, height: 1.0 * scale)
        shadow.shadowBlurRadius = 2.0 * scale
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ]
        #elseif canImport(UIKit)
        // UIKit uses NSShadow from Foundation, not AppKit
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
        shadow.shadowOffset = CGSize(width: 0, height: 1.0 * scale)
        shadow.shadowBlurRadius = 2.0 * scale
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .shadow: shadow
        ]
        #endif
       
        
        let nsString = NSString(string: timestamp)
        let stringSize = nsString.size(withAttributes: textAttributes)

        // Calculate text position for bottom right placement with proportional margins
        let margin = size.width * 0.02
        let textX = rect.maxX - stringSize.width - margin
        let bottomMargin = size.height * 0.02
        let textY = rect.maxY - stringSize.height - bottomMargin
        
        // Draw text directly without background
        newContext.saveGState()
        newContext.textMatrix = CGAffineTransform.identity
        newContext.translateBy(x: textX, y: textY)
        
        let attributedString = NSAttributedString(string: timestamp, attributes: textAttributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        CTLineDraw(line, newContext)
        newContext.restoreGState()
        
        // Return the final image
        guard let finalImage = newContext.makeImage() else {
            logger.error("❌ Failed to create final image with timestamp")
            return image
        }
        
        return finalImage
    }
} 
