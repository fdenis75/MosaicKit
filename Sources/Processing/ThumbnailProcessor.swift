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
@available(macOS 15, iOS 18, *)
public final class ThumbnailProcessor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.hypermovie", category: "thumbnail-processor")
    private let config: MosaicConfiguration
    private let signposter = OSSignposter()
    
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
      //  logger.debug("🎬 Starting thumbnail extraction - File: \(file.lastPathComponent)")
    //    logger.debug("📐 \(file.lastPathComponent) - Layout details - Grid: \(layout.rows)x\(layout.cols), Size: \(layout.thumbnailSize.width)x\(layout.thumbnailSize.height)")
        
        let state = signposter.beginInterval("Extract Thumbnails")
        defer { signposter.endInterval("Extract Thumbnails", state) }
        
        let duration = try await asset.load(.duration).seconds
        let generator = configureGenerator(for: asset, accurate: accurate, preview: preview, layout: layout)
       // logger.debug("⚙️ Generator configured - Duration: \(duration)s, Accurate: \(accurate)")
        
        let times = try await calculateExtractionTimes(
            duration: duration,
            count: layout.positions.count
        )
        //logger.debug("⏱️ Calculated \(times.count) extraction times")
        
        var thumbnails: [Int: (CGImage, String)] = [:] // Use dictionary to track by index
        var failedIndices: [Int] = []
        var currentIndex = 0

        // First pass: Extract all frames
        for await result in generator.images(for: times) {
            let index = currentIndex
            currentIndex += 1

            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                let timestamp = self.formatTimestamp(seconds: actual.seconds)
                let imageWithTimestamp = addTimestampToImage(image: image, timestamp: timestamp, size: layout.thumbnailSizes[index])
                thumbnails[index] = (imageWithTimestamp, timestamp)
            case .failure(requestedTime: let requestedTime, error: let error):
                logger.warning("⚠️ Frame extraction failed at \(self.formatTimestamp(seconds: requestedTime.seconds)): \(error.localizedDescription)")
                failedIndices.append(index)
            }
        }

        // Retry failed extractions once
        if !failedIndices.isEmpty {
            logger.debug("🔄 Retrying \(failedIndices.count) failed extractions...")
            let failedTimes = failedIndices.map { times[$0] }
            var retryIndex = 0
            var stillFailed: [Int] = []

            for await result in generator.images(for: failedTimes) {
                let originalIndex = failedIndices[retryIndex]
                retryIndex += 1

                switch result {
                case .success(requestedTime: _, image: let image, actualTime: let actual):
                    let timestamp = self.formatTimestamp(seconds: actual.seconds)
                    let imageWithTimestamp = addTimestampToImage(image: image, timestamp: timestamp, size: layout.thumbnailSizes[originalIndex])
                    thumbnails[originalIndex] = (imageWithTimestamp, timestamp)
                    logger.debug("✅ Retry successful for frame \(originalIndex)")
                case .failure(requestedTime: let requestedTime, error: let error):
                    logger.error("❌ Retry failed for frame \(originalIndex) at \(self.formatTimestamp(seconds: requestedTime.seconds)): \(error.localizedDescription)")
                    stillFailed.append(originalIndex)
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
                domain: "com.hypermovie",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract any thumbnails"]
            ))
        }
        
        let successCount = thumbnails.count
        let totalExpected = times.count
        logger.debug("✅ \(file.lastPathComponent) - Thumbnail extraction complete - Success: \(successCount)/\(totalExpected)")

        // Convert dictionary back to sorted array
        return (0..<totalExpected).compactMap { index in
            thumbnails[index]
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
        
        // Calculate final mosaic size
        var mosaicSize = layout.mosaicSize
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
            context.draw(headerImage, in: CGRect(x: 0, y: 0, width: mosaicSize.width, height: CGFloat(metadataHeight)))
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
            // CGRect works on both platforms
            let rect = CGRect(
                x: CGFloat(position.x), 
                y: CGFloat(position.y) + CGFloat(yOffset), 
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
            generator.requestedTimeToleranceBefore = CMTime(seconds: 10, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 10, preferredTimescale: 600)
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
    ///   - height: The height of the metadata header (matching first row of thumbnails)
    ///   - backgroundColor: Optional background color (if nil, platform-specific default will be used)
    /// - Returns: A CGImage containing the metadata header
    public func createMetadataHeader(
        for video: VideoInput,
        width: Int,
        height: Int? = nil,
        backgroundColor: CGColor? = nil,
        forIphone: Bool = false
    ) -> CGImage? {
        // Set default background color based on platform
        #if canImport(AppKit)
        let bgColor = backgroundColor ?? NSColor(white: 0.1, alpha: 0.25).cgColor
        #elseif canImport(UIKit)
        let bgColor = backgroundColor ?? UIColor(white: 0.1, alpha: 0.25).cgColor
        #endif
        logger.debug("🏷️ Creating enhanced metadata header image - Width: \(width)")
        
        // Use provided height or calculate based on width
        var metadataHeight = height ?? Int(round(Double(width) * 0.08))
        
        // Format resolution using video dimensions from metadata
        let resolution = "\(video.metadata.custom["width"] ?? "0")×\(video.metadata.custom["height"] ?? "0")"
        
        let padding: CGFloat = 8.0
        
        let fontSize = max(forIphone ? 6.0 : 12.0, CGFloat(metadataHeight) / 4.0)
        
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
        
        // Draw a fully transparent background first to let the blurred background show through
        context.clear(CGRect(x: 0, y: 0, width: width, height: metadataHeight))
        
        // Create dark semi-transparent background for metadata (50% opacity to see background better)
        context.setFillColor(bgColor)  // Using our platform-specific background color
       
        let bgRect = CGRect(x: 0, y: 0, width: width, height: metadataHeight)
        context.fill(bgRect)
        
        // Format duration
        let formattedDuration: String
        // Safely unwrap duration and check if positive
        if let duration = video.duration, duration > 0 {
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            let seconds = Int(duration) % 60
            formattedDuration = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            formattedDuration = "Unknown"
        }
        
        // Format file size
        let formattedFileSize: String
        if let fileSize = video.fileSize {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB]
            formatter.countStyle = .file
            formattedFileSize = formatter.string(fromByteCount: fileSize)
        } else {
            formattedFileSize = "Unknown"
        }
        
        // Prepare the metadata in two rows for better readability
        let row1Items = [
            "Title: \(video.title)",
            "Duration: \(formattedDuration)",
            "Size: \(formattedFileSize)"
        ]
        
        let row2Items = [
            "Codec: \(video.metadata.codec ?? "Unknown")",
            "Resolution: \(resolution)",
            "Bitrate: \(formatBitrate(video.metadata.bitrate))"
        ]
        
        // Get filepath
        // Safely unwrap url before accessing path
        let filePath = "Path: \(video.url.path)"
        
        // Set up text attributes using CoreText with enhanced styling
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let smallerFont = CTFontCreateWithName("Helvetica" as CFString, fontSize * 0.8, nil)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineSpacing = forIphone ? 1.0 : 2.0 // Add more spacing between lines
        
#if canImport(AppKit)
        // for  iphine, all text is white
        // Create the attributed strings with enhanced styling
        let row1Attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: forIphone ? NSColor.white : NSColor.gray,
            .paragraphStyle: paragraphStyle,
         //   .strokeWidth: -0.5, // Text outline for better visibility against semi-transparent background
           // .strokeColor: NSColor.black.withAlphaComponent(0.5)
           
        ]
        
        let row2Attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: forIphone ? NSColor.white : NSColor.darkGray,
            .paragraphStyle: paragraphStyle,
         //   .strokeWidth: -0.5, // Text outline
          //  .strokeColor: NSColor.black.withAlphaComponent(0.5)
        
        ]
        
        let pathAttributes: [NSAttributedString.Key: Any] = [
            .font: smallerFont,
        
            .foregroundColor: forIphone ? NSColor.white : NSColor.darkGray,// Brighter text for better visibility
            .paragraphStyle: paragraphStyle,
            //.strokeWidth: -0.3, // Subtle text outline
           // .strokeColor: NSColor.black.withAlphaComponent(0.3)
          
        ]
#elseif canImport(UIKit)
        let row1Attributes: [NSAttributedString.Key: Any] = [
            .font: font,

            .foregroundColor: UIColor.gray,
            .paragraphStyle: paragraphStyle,
            .strokeWidth: -0.5, // Text outline for better visibility against semi-transparent background
            .strokeColor: UIColor.black.withAlphaComponent(0.5)
        ]
        
        let row2Attributes: [NSAttributedString.Key: Any] = [
            .font: font,

            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: paragraphStyle,
            .strokeWidth: -0.5, // Text outline
            .strokeColor: UIColor.black.withAlphaComponent(0.5)
        ]
        
        let pathAttributes: [NSAttributedString.Key: Any] = [
            .font: smallerFont,

            .foregroundColor: UIColor(white: 1.0, alpha: 0.9), // Brighter text for better visibility
            .paragraphStyle: paragraphStyle,
            .strokeWidth: -0.3, // Subtle text outline
            .strokeColor: UIColor.black.withAlphaComponent(0.3)
        ]
        
        
        
#endif
        // if for iphone, the lines width should be more than 1000 px
        
        // Join rows with separators
        let row1Text = row1Items.joined(separator: " | ")
        let row2Text = row2Items.joined(separator: " | ")
        
        // Create attributed strings
        let row1AttributedString = NSAttributedString(string: row1Text, attributes: row1Attributes)
        let row2AttributedString = NSAttributedString(string: row2Text, attributes: row2Attributes)
        let pathAttributedString = NSAttributedString(string: filePath, attributes: pathAttributes)
        
        // Create lines
        let row1Line = CTLineCreateWithAttributedString(row1AttributedString)
        let row2Line = CTLineCreateWithAttributedString(row2AttributedString)
        let pathLine = CTLineCreateWithAttributedString(pathAttributedString)
        
        // Calculate text bounds for positioning
        let row1Bounds = CTLineGetBoundsWithOptions(row1Line, .useOpticalBounds)
        let row2Bounds = CTLineGetBoundsWithOptions(row2Line, .useOpticalBounds)
        let pathBounds = CTLineGetBoundsWithOptions(pathLine, .useOpticalBounds)
        
        // Calculate padding from the left edge
        let leftPadding: CGFloat = 20.0
        
        // Draw row 1 (top third)
        let row1YPos = CGFloat(metadataHeight) * 0.75
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: leftPadding, y: row1YPos)
        
        CTLineDraw(row1Line, context)
        context.restoreGState()
        
        // Draw row 2 (middle third)
        let row2YPos = CGFloat(metadataHeight) * 0.45
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: leftPadding, y: row2YPos)
        CTLineDraw(row2Line, context)
        context.restoreGState()
        
        // Draw file path (bottom third)
        let pathYPos = CGFloat(metadataHeight) * 0.15
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: leftPadding, y: pathYPos)
        CTLineDraw(pathLine, context)
        context.restoreGState()
        
        guard let headerImage = context.makeImage() else {
            logger.error("❌ Failed to create metadata header image")
            return nil
        }
        
        logger.debug("✅ Created enhanced metadata header - Size: \(width)×\(metadataHeight)")
        return headerImage
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
        let padding: CGFloat = 16.0
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
        let bgRect = CGRect(x: 0, y: 0, width: width, height: metadataHeight)
        context.fill(bgRect)
        
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
        let padding: CGFloat = 16.0
        let fontSize = max(12.0, CGFloat(metadataHeight) / 3.0)
        
        // Draw a semi-transparent background bar at the top
        context.saveGState()
        
        // First clear the area to ensure transparency
        context.clear(CGRect(x: 0, y: 0, width: width, height: metadataHeight))
        
        // Create dark semi-transparent background for metadata - more transparent to match main method
        #if canImport(AppKit)
        context.setFillColor(NSColor(white: 0.1, alpha: 0.5).cgColor)
        #elseif canImport(UIKit)
        context.setFillColor(UIColor(white: 0.1, alpha: 0.5).cgColor)
        #endif
        let bgRect = CGRect(x: 0, y: 0, width: width, height: metadataHeight)
        context.fill(bgRect)
        
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
    ///   - timestamp: The timestamp string to add
    ///   - size: The size of the thumbnail
    /// - Returns: CGImage with timestamp overlay and enhanced visual design
    private func addTimestampToImage(image: CGImage, timestamp: String, size: CGSize) -> CGImage {
        // Create a context for the image with appropriate scale
        let scale = max(1.0, min(1.2,Double(image.width) / size.width)) // Handle high-resolution images
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
        
        // Add subtle vignette effect for depth (Apple design often uses this)
        let vignetteWidth = CGFloat(image.width) * 0.15
        let vignetteHeight = CGFloat(image.height) * 0.15
        
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
            context.restoreGState()
            // Draw timestamp without vignette if gradient creation fails
            return addTimestampToBaseImage(image: image, timestamp: timestamp, size: size, context: context, rect: rect)
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
        
        // Calculate font size - more elegant proportions for Apple-like design
        // Apple often uses highly legible but slightly smaller fonts in their designs
        // Increased by 50% for better visibility
        let fontSize = max(11.0, min(17.0, Double(image.width) / 18)) * scale * 1.5
        
        // Use a system font with bold weight for better readability
        #if canImport(AppKit)
        let systemFont = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        #elseif canImport(UIKit)
        let systemFont = UIFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
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
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ]
        #elseif canImport(UIKit)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: systemFont,
            .foregroundColor: UIColor.white,
            .shadow: shadow
        ]
        #endif
        
        let nsString = NSString(string: timestamp)
        let stringSize = nsString.size(withAttributes: textAttributes)
        
        // Padding for the pill-shaped background (Apple often uses minimal padding)
        let paddingX: CGFloat = 10.0 * scale
        let paddingY: CGFloat = 5.0 * scale
        
        // Calculate background rectangle dimensions with more subtle proportions
        let bgWidth = stringSize.width + (paddingX * 2)
        let bgHeight = stringSize.height + (paddingY * 2)
        
        // Position at the bottom right corner - Apple often uses this placement
        // for timestamps and similar metadata overlays
        let margin = 12.0 * scale
        let bgX = rect.maxX - bgWidth - margin
        // Force placement at the bottom (not top) by using a smaller value from the bottom edge
        // This ensures the timestamp appears at the bottom right corner
        let bottomMargin = 20.0 * scale // Slightly larger margin from bottom than sides for better visual balance
        let bgY = rect.maxY - bgHeight - bottomMargin
        
        // Draw a pill-shaped background with Apple's signature blur effect
        let bgRect = CGRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)
        
        // Apple-style pill shape has more pronounced rounding (half the height)
        let pillRadius = bgHeight / 2
        
        // Use a subtle gradient background for the pill
        // Apple often uses gradients rather than flat colors
       #if os(macOS)
        let pillColors = [
            NSColor(white: 0.12, alpha: 0.55).cgColor,  // Slightly lighter at top
            NSColor(white: 0.08, alpha: 0.75).cgColor   // Slightly darker at bottom
        ]
        #elseif os(iOS)
        let pillColors = [
            UIColor(white: 0.12, alpha: 0.55).cgColor,  // Slightly lighter at top
            UIColor(white: 0.08, alpha: 0.75).cgColor   // Slightly darker at bottom
        ]
        #endif
        let pillLocations: [CGFloat] = [0.0, 1.0]
        
        guard let pillGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: pillColors as CFArray,
            locations: pillLocations
        ) else {
            // Fallback to solid color if gradient creation fails
            #if canImport(AppKit)
            context.setFillColor(NSColor(white: 0.1, alpha: 0.8).cgColor)
            #elseif canImport(UIKit)
            context.setFillColor(UIColor(white: 0.1, alpha: 0.8).cgColor)
            #endif
            drawPillBackground(in: context, rect: bgRect, radius: pillRadius)
            drawTimestampText(in: context, text: timestamp, attributes: textAttributes, rect: bgRect)
            
            // Return the final image
            guard let finalImage = context.makeImage() else {
                logger.error("❌ Failed to create final image with timestamp")
                return image
            }
            return finalImage
        }
        
        // Draw the pill shape
        let pillPath = CGPath(roundedRect: bgRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
        context.addPath(pillPath)
        context.clip()
        
        // Fill with gradient
        context.drawLinearGradient(
            pillGradient,
            start: CGPoint(x: bgRect.midX, y: bgRect.minY),
            end: CGPoint(x: bgRect.midX, y: bgRect.maxY),
            options: []
        )
        
        // Reset clipping for further drawing
        context.resetClip()
        
        // Draw the text with precise positioning
        // Calculate position to vertically center the text in the pill
        let textX = bgX + (bgWidth - stringSize.width) / 2
        // Add a tiny adjustment to ensure perfect vertical centering
        let textY = bgY + (bgHeight - stringSize.height) / 2 + 1.0 * scale
        let textRect = CGRect(x: textX, y: textY, width: stringSize.width, height: stringSize.height)
        
        // Draw text
        context.saveGState()
        context.textMatrix = CGAffineTransform.identity
        context.translateBy(x: textRect.origin.x, y: textRect.origin.y)
        
        let attributedString = NSAttributedString(string: timestamp, attributes: textAttributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        CTLineDraw(line, context)
        //context.restoreGState()
        
        // Apply final subtle border highlight for depth (Apple design detail)
        #if canImport(AppKit)
        let whiteColor = NSColor.white.withAlphaComponent(0.15).cgColor
        #elseif canImport(UIKit)
        let whiteColor = UIColor.white.withAlphaComponent(0.15).cgColor
        #endif
        context.setStrokeColor(whiteColor)
        context.setLineWidth(0.5 * scale)
        context.addPath(pillPath)
        context.strokePath()
        
        // Return the final image
        guard let finalImage = context.makeImage() else {
            logger.error("❌ Failed to create final image with timestamp")
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
    
    /// Fallback method for adding timestamp to image
    private func addTimestampToBaseImage(image: CGImage, timestamp: String, size: CGSize, context: CGContext, rect: CGRect) -> CGImage {
        // Start fresh with a properly configured context
        let scale = max(1.0, Double(image.width) / size.width)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
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
        newContext.beginPath()
        newContext.addPath(roundedPath)
        newContext.closePath()
        newContext.clip()
        
        // Draw original image
        newContext.draw(image, in: rect)
        newContext.restoreGState()
        
        // Continue with text rendering
        // Increased by 50% for better visibility
        let fontSize = max(11.0, min(17.0, Double(image.width) / 18)) * scale * 1.5
        
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
        
        // Calculate text position for bottom right placement
        let margin = 12.0 * scale
        let textX = rect.maxX - stringSize.width - margin
        // Match the same bottom margin as the main method
        let bottomMargin = 20.0 * scale
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
