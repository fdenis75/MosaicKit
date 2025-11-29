import Foundation
import CoreGraphics
import Accelerate
import CoreImage
import OSLog
import DominantColors

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A Core Graphics and vImage-based image processor for high-performance mosaic generation on iOS
/// This implementation mirrors MetalImageProcessor but uses vImage/Accelerate for performance
@available(macOS 14, iOS 17, *)
public final class CoreGraphicsImageProcessor: @unchecked Sendable {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.mosaicKit", category: "cg-processor")
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "cg-processor")

    // Buffer pool for reusable vImage buffers
    private var bufferPool: [vImage_Buffer] = []
    private let poolLock = NSLock()

    // Performance metrics
    private var lastExecutionTime: CFAbsoluteTime = 0
    private var totalExecutionTime: CFAbsoluteTime = 0
    private var operationCount: Int = 0

    // MARK: - Initialization

    /// Initialize the Core Graphics image processor
    public init() throws {
        let initState = signposter.beginInterval("Initialize CG Processor")
        logger.debug("🔧 Initializing Core Graphics image processor with vImage acceleration")
        defer { signposter.endInterval("Initialize CG Processor", initState) }

        // Verify vImage is available (always true on modern iOS/macOS)
        logger.debug("✅ vImage/Accelerate framework available")
    }

    deinit {
        // Clean up buffer pool
        poolLock.lock()
        defer { poolLock.unlock() }
        for var buffer in bufferPool {
            buffer.data.deallocate()
        }
        bufferPool.removeAll()
    }

    // MARK: - Public Methods

    /// Scale an image to a new size using vImage high-quality interpolation
    /// - Parameters:
    ///   - image: The source CGImage
    ///   - size: The target size
    /// - Returns: A new scaled CGImage
    public func scaleImage(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        let targetWidth = Int(size.width)
        let targetHeight = Int(size.height)

        // Create source vImage buffer from CGImage
        var sourceBuffer = try createVImageBuffer(from: image)
        defer { freeVImageBuffer(&sourceBuffer) }

        // Create destination buffer
        var destBuffer = vImage_Buffer()
        destBuffer.width = vImagePixelCount(targetWidth)
        destBuffer.height = vImagePixelCount(targetHeight)
        destBuffer.rowBytes = targetWidth * 4
        destBuffer.data = UnsafeMutableRawPointer.allocate(
            byteCount: targetWidth * targetHeight * 4,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { freeVImageBuffer(&destBuffer) }

        // Use vImage high-quality scaling (Lanczos)
        let error = vImageScale_ARGB8888(
            &sourceBuffer,
            &destBuffer,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )

        guard error == kvImageNoError else {
            logger.error("❌ vImage scaling failed with error: \(error)")
            throw CoreGraphicsProcessorError.scalingFailed
        }

        // Convert vImage buffer back to CGImage
        let scaledImage = try createCGImage(from: destBuffer)
        return scaledImage
    }

    /// Composite a source image onto a destination image at a specific position
    /// - Parameters:
    ///   - sourceImage: The source CGImage to composite
    ///   - destinationImage: The destination CGImage
    ///   - position: The position to place the source image
    /// - Returns: A new CGImage with the composited result
    public func compositeImage(
        _ sourceImage: CGImage,
        onto destinationImage: CGImage,
        at position: CGPoint
    ) throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        let destWidth = destinationImage.width
        let destHeight = destinationImage.height

        // Create a mutable copy of the destination
        guard let context = CGContext(
            data: nil,
            width: destWidth,
            height: destHeight,
            bitsPerComponent: 8,
            bytesPerRow: destWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ Failed to create CGContext for compositing")
            throw CoreGraphicsProcessorError.contextCreationFailed
        }

        // Draw the destination image first
        context.draw(destinationImage, in: CGRect(x: 0, y: 0, width: destWidth, height: destHeight))

        // Draw the source image at the specified position with alpha blending
        let sourceRect = CGRect(
            x: position.x,
            y: position.y,
            width: CGFloat(sourceImage.width),
            height: CGFloat(sourceImage.height)
        )
        context.draw(sourceImage, in: sourceRect)

        // Create the composited image
        guard let compositedImage = context.makeImage() else {
            logger.error("❌ Failed to create composited CGImage")
            throw CoreGraphicsProcessorError.cgImageCreationFailed
        }

        return compositedImage
    }

    /// Create a new image filled with a solid color
    /// - Parameters:
    ///   - size: The size of the image
    ///   - color: The color to fill with (RGBA, 0.0-1.0)
    /// - Returns: A new CGImage filled with the specified color
    public func createFilledImage(size: CGSize, color: SIMD4<Float>) throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        let width = Int(size.width)
        let height = Int(size.height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ Failed to create CGContext for filled image")
            throw CoreGraphicsProcessorError.contextCreationFailed
        }

        // Convert SIMD4<Float> to CGColor
        let cgColor = CGColor(
            red: CGFloat(color.x),
            green: CGFloat(color.y),
            blue: CGFloat(color.z),
            alpha: CGFloat(color.w)
        )

        context.setFillColor(cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let filledImage = context.makeImage() else {
            logger.error("❌ Failed to create filled CGImage")
            throw CoreGraphicsProcessorError.cgImageCreationFailed
        }

        return filledImage
    }

    /// Process images to create a background with dominant color gradient
    /// - Parameters:
    ///   - images: Sample images to extract colors from
    ///   - maxColors: Maximum number of colors to extract per image
    ///   - outputSize: Size of the output background image
    /// - Returns: A CGImage with gradient background
    func processImagesToBackground(images: [CGImage], maxColors: Int, outputSize: CGSize) -> CGImage? {
        guard !images.isEmpty else { return nil }

        // Step 1: Sample images
        let sampleCount = min(3, images.count)
        let step = max(1, images.count / sampleCount)
        let sampledImages = stride(from: 0, to: images.count, by: step).prefix(sampleCount).map { images[$0] }

        // Step 2: Extract dominant colors
        var allColors: [CGColor] = []
        let flags: [DominantColors.Options] = [
            .excludeBlack,
            .excludeWhite,
            .excludeGray
        ]

        for image in sampledImages {
            do {
                #if os(macOS)
                let colors = try DominantColors.dominantColors(
                    image: image,
                    quality: .fair,
                    algorithm: .euclidean,
                    maxCount: maxColors,
                    options: flags,
                    sorting: .lightness
                )
                allColors.append(contentsOf: colors)
                #elseif os(iOS)
                let colors = try DominantColors.dominantColors(
                    image: image,
                    quality: .fair,
                    algorithm: .CIE94,
                    maxCount: maxColors,
                    options: flags,
                    sorting: .lightness
                )
                allColors.append(contentsOf: colors)
                #endif
            } catch {
                logger.error("❌ Failed to extract colors: \(error.localizedDescription)")
            }
        }

        // Step 3: Select top colors
        let top3LightColors = allColors.sorted { color1, color2 in
            let components1 = color1.components ?? [0, 0, 0, 1]
            let components2 = color2.components ?? [0, 0, 0, 1]
            let brightness1 = (components1[0] + components1[1] + components1[2]) / 3.0
            let brightness2 = (components2[0] + components2[1] + components2[2]) / 3.0
            return brightness1 > brightness2
        }.prefix(3)

        // Step 4: Generate gradient image
        let gradientImage: CGImage?

        #if os(iOS)
        UIGraphicsBeginImageContext(outputSize)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        #else
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        #endif

        // Create gradient colors array
        let colorsArray: [CGColor]
        if top3LightColors.isEmpty {
            colorsArray = [
                CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0),
                CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
            ]
        } else {
            colorsArray = Array(top3LightColors)
        }

        let cgColors = colorsArray as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: cgColors,
            locations: nil
        ) else { return nil }

        ctx.drawLinearGradient(
            gradient,
            start: CGPoint.zero,
            end: CGPoint(x: outputSize.width, y: outputSize.height),
            options: []
        )

        #if os(iOS)
        gradientImage = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()
        #else
        ctx.flush()
        gradientImage = ctx.makeImage()
        #endif

        guard let imageForBlur = gradientImage else { return nil }

        // Step 5: Apply Gaussian blur using Core Image
        let ciImage = CIImage(cgImage: imageForBlur)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(12.0, forKey: kCIInputRadiusKey)
        guard let outputCI = blurFilter.outputImage else { return nil }

        let ciContext = CIContext()
        let cropped = outputCI.cropped(to: ciImage.extent)
        guard let blurredCG = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }

        return blurredCG
    }

    /// Generate a mosaic image using Core Graphics and vImage acceleration
    /// - Parameters:
    ///   - frames: Array of frames with timestamps
    ///   - layout: Layout information
    ///   - metadata: Video metadata
    ///   - config: Mosaic configuration
    ///   - metadataHeader: Optional pre-generated metadata header image
    ///   - forIphone: Whether to use simple gray background (iPhone mode)
    ///   - progressHandler: Optional progress handler to update progress
    /// - Returns: Generated mosaic image
    public func generateMosaic(
        from frames: [(image: CGImage, timestamp: String)],
        layout: MosaicLayout,
        metadata: VideoMetadata,
        config: MosaicConfiguration,
        metadataHeader: CGImage? = nil,
        forIphone: Bool = false,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        logger.debug("🎨 Starting Core Graphics mosaic generation - Frames: \(frames.count)")
        logger.debug("📐 Layout size: \(layout.mosaicSize.width)x\(layout.mosaicSize.height)")

        // Determine if we need space for the metadata header
        let hasMetadata = config.includeMetadata && metadataHeader != nil
        let metadataHeight = hasMetadata ? metadataHeader!.height : 0

        // Calculate adjusted mosaic size to accommodate metadata header
        var mosaicSize = layout.mosaicSize
        if hasMetadata {
            mosaicSize.height += CGFloat(metadataHeight)
        }

        // Create background image
        progressHandler?(0.1)
        var mosaicImage: CGImage
        if forIphone {
            let color = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
            mosaicImage = try createFilledImage(size: mosaicSize, color: color)
        } else {
            if let background = processImagesToBackground(
                images: frames.map { $0.image },
                maxColors: 5,
                outputSize: mosaicSize
            ) {
                mosaicImage = background
            } else {
                // Fallback to gray if color extraction fails
                let color = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
                mosaicImage = try createFilledImage(size: mosaicSize, color: color)
            }
        }
        progressHandler?(0.2)

        // If we have a metadata header, composite it at the top of the mosaic
        if hasMetadata, let headerImage = metadataHeader {
            logger.debug("🏷️ Adding metadata header - Size: \(headerImage.width)×\(headerImage.height)")
            mosaicImage = try compositeImage(
                headerImage,
                onto: mosaicImage,
                at: CGPoint(x: 0, y: 0)
            )
        }

        // Process frames in batches to maintain performance
        let batchSize = 20
        let totalBatches = (frames.count + batchSize - 1) / batchSize
        progressHandler?(0.3)

        for batchStart in stride(from: 0, to: frames.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, frames.count)
            let batchFrames = frames[batchStart..<batchEnd]
            let currentBatch = batchStart / batchSize

            logger.debug("🔄 Processing batch \(currentBatch + 1)/\(totalBatches): frames \(batchStart+1)-\(batchEnd)")

            for (index, frame) in batchFrames.enumerated() {
                let actualIndex = batchStart + index
                guard actualIndex < layout.positions.count else { break }

                let position = layout.positions[actualIndex]
                let size = layout.thumbnailSizes[actualIndex]

                // Adjust position to account for metadata header
                let adjustedY = position.y + (hasMetadata ? Int(metadataHeight) : 0)

                // Scale the frame if needed
                let scaledFrame: CGImage
                if frame.image.width != Int(size.width) || frame.image.height != Int(size.height) {
                    scaledFrame = try scaleImage(
                        frame.image,
                        to: CGSize(width: size.width, height: size.height)
                    )
                } else {
                    scaledFrame = frame.image
                }

                // Composite the frame onto the mosaic at adjusted position
                mosaicImage = try compositeImage(
                    scaledFrame,
                    onto: mosaicImage,
                    at: CGPoint(x: position.x, y: adjustedY)
                )

                // Update progress based on frame completion
                let frameProgress = 0.3 + (0.6 * Double(actualIndex + 1) / Double(frames.count))
                progressHandler?(frameProgress)

                if Task.isCancelled {
                    logger.warning("❌ Mosaic creation cancelled")
                    throw CoreGraphicsProcessorError.cancelled
                }
            }
        }

        let generationTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.debug("✅ Core Graphics mosaic generation complete - Size: \(mosaicImage.width)x\(mosaicImage.height) in \(generationTime) seconds")
        progressHandler?(1.0)

        return mosaicImage
    }

    /// Get performance metrics for the Core Graphics processor
    /// - Returns: A dictionary of performance metrics
    public func getPerformanceMetrics() -> [String: Any] {
        return [
            "averageExecutionTime": operationCount > 0 ? totalExecutionTime / Double(operationCount) : 0,
            "totalExecutionTime": totalExecutionTime,
            "operationCount": operationCount,
            "lastExecutionTime": lastExecutionTime
        ]
    }

    // MARK: - Private Methods

    /// Create a vImage buffer from a CGImage
    private func createVImageBuffer(from cgImage: CGImage) throws -> vImage_Buffer {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        // Allocate memory for the buffer
        guard let data = UnsafeMutableRawPointer.allocate(
            byteCount: bytesPerRow * height,
            alignment: MemoryLayout<UInt8>.alignment
        ) as UnsafeMutableRawPointer? else {
            throw CoreGraphicsProcessorError.bufferAllocationFailed
        }

        // Create a CGContext to draw the image into the buffer
        guard let context = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            data.deallocate()
            throw CoreGraphicsProcessorError.contextCreationFailed
        }

        // Draw the image into the context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create and return the vImage buffer
        var buffer = vImage_Buffer()
        buffer.data = data
        buffer.width = vImagePixelCount(width)
        buffer.height = vImagePixelCount(height)
        buffer.rowBytes = bytesPerRow

        return buffer
    }

    /// Create a CGImage from a vImage buffer
    private func createCGImage(from buffer: vImage_Buffer) throws -> CGImage {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        let bytesPerRow = buffer.rowBytes

        // Create a data provider from the buffer
        let data = Data(bytes: buffer.data, count: bytesPerRow * height)
        guard let dataProvider = CGDataProvider(data: data as CFData) else {
            throw CoreGraphicsProcessorError.dataProviderCreationFailed
        }

        // Create a CGImage from the data provider
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CoreGraphicsProcessorError.cgImageCreationFailed
        }

        return cgImage
    }

    /// Free memory allocated for a vImage buffer
    private func freeVImageBuffer(_ buffer: inout vImage_Buffer) {
        if let data = buffer.data {
            data.deallocate()
            buffer.data = nil
        }
    }

    /// Track performance metrics
    private func trackPerformance(startTime: CFAbsoluteTime) {
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        lastExecutionTime = executionTime
        totalExecutionTime += executionTime
        operationCount += 1
    }
}

// MARK: - Errors

/// Errors that can occur during Core Graphics processing
public enum CoreGraphicsProcessorError: Error {
    case contextCreationFailed
    case scalingFailed
    case bufferAllocationFailed
    case dataProviderCreationFailed
    case cgImageCreationFailed
    case cancelled
}
