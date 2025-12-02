import Foundation
import Metal
import MetalKit
import CoreImage
import CoreVideo
import OSLog
import DominantColors

#if os(iOS)
import UIKit
typealias XImage = UIImage
#elseif os(macOS)
import AppKit
typealias XImage = NSImage
#endif

/// A Metal-based image processor for high-performance mosaic generation
@available(macOS 14, iOS 17, *)
public final class MetalImageProcessor: @unchecked Sendable {
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.mosaicKit", category: "metal-processor")
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var textureCache: CVMetalTextureCache?
    private let textureLoader: MTKTextureLoader
    private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "metal-processor")
    
    // Compute pipelines for different operations
    private let scalePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let fillPipeline: MTLComputePipelineState
    private let borderPipeline: MTLComputePipelineState
    // Note: shadowPipeline removed - unused in codebase
    
    // Performance metrics
    private var lastExecutionTime: CFAbsoluteTime = 0
    private var totalExecutionTime: CFAbsoluteTime = 0
    private var operationCount: Int = 0
    
    // MARK: - Initialization
    
    /// Initialize the Metal image processor
    public init() throws {
        let initState = signposter.beginInterval("Initialize Metal Processor")
       
        
        logger.debug("🔧 Initializing Metal image processor")
        
        // Get default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("❌ No Metal device available")
            throw MetalProcessorError.deviceNotAvailable
        }
        self.device = device
        logger.debug("✅ Using Metal device: \(device.name)")
        
        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            logger.error("❌ Failed to create command queue")
            throw MetalProcessorError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // Load Metal shader library
        do {
            logger.debug("📦 Bundle.module path: \(Bundle.module.bundlePath)")
            
            // Try to load default library first
            if let defaultLib = try? device.makeDefaultLibrary() {
                self.library = defaultLib
            } else {
                // Fallback: Try to compile from source if available in bundle
                logger.debug("🔄 Attempting to compile from source in bundle")
                if let shaderPath = Bundle.module.path(forResource: "MetalShaders", ofType: "metal") {
                    let source = try String(contentsOfFile: shaderPath, encoding: .utf8)
                    self.library = try device.makeLibrary(source: source, options: nil)
                    logger.debug("✅ Compiled Metal library from source")
                } else {
                     throw MetalProcessorError.libraryCreationFailed
                }
            }
        } catch {
             logger.error("❌ Failed to load Metal library: \(error.localizedDescription)")
             throw MetalProcessorError.libraryCreationFailed
        }
        
        // Create texture cache for efficient conversion between CVPixelBuffer and MTLTexture
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if status != kCVReturnSuccess {
            logger.error("❌ Failed to create texture cache: \(status)")
            throw MetalProcessorError.textureCacheCreationFailed
        }
        self.textureCache = textureCache

        // Create texture loader for efficient CGImage to MTLTexture conversion
        self.textureLoader = MTKTextureLoader(device: device)

        // Create compute pipelines
        do {
            guard let scaleFunction = library.makeFunction(name: "scaleTexture"),
                  let compositeFunction = library.makeFunction(name: "compositeTextures"),
                  let fillFunction = library.makeFunction(name: "fillTexture"),
                  let borderFunction = library.makeFunction(name: "addBorder") else {
                logger.error("❌ Failed to create Metal functions")
                throw MetalProcessorError.functionNotFound
            }

            self.scalePipeline = try device.makeComputePipelineState(function: scaleFunction)
            self.compositePipeline = try device.makeComputePipelineState(function: compositeFunction)
            self.fillPipeline = try device.makeComputePipelineState(function: fillFunction)
            self.borderPipeline = try device.makeComputePipelineState(function: borderFunction)
            // Note: shadowPipeline removed - unused shader

            logger.debug("✅ Created all compute pipelines")
        } catch {
            logger.error("❌ Failed to create compute pipeline: \(error.localizedDescription)")
            throw MetalProcessorError.pipelineCreationFailed
        }
         defer { signposter.endInterval("Initialize Metal Processor", initState) }
     //   logger.debug("✅ Metal image processor initialized successfully")
    }
    
    // MARK: - Public Methods
    
    /// Create a Metal texture directly from a CVPixelBuffer using CVMetalTextureCache (zero-copy)
    /// - Parameter pixelBuffer: The source CVPixelBuffer (from VideoToolbox)
    /// - Returns: A Metal texture containing the image data
    /// - Note: This is the PREFERRED method for VideoToolbox frames as it avoids CPU-GPU copies
    public func createTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        guard let textureCache = textureCache else {
            logger.error("❌ Texture cache not available")
            throw MetalProcessorError.textureCacheCreationFailed
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rgba8Unorm,
            width,
            height,
            0,
            &cvMetalTexture
        )

        guard status == kCVReturnSuccess, let cvTexture = cvMetalTexture else {
            logger.error("❌ Failed to create texture from pixel buffer: \(status)")
            throw MetalProcessorError.textureCreationFailed
        }

        guard let texture = CVMetalTextureGetTexture(cvTexture) else {
            logger.error("❌ Failed to get Metal texture from CVMetalTexture")
            throw MetalProcessorError.textureCreationFailed
        }

        return texture
    }

    /// Create a Metal texture from a CGImage using MTKTextureLoader for efficiency
    /// - Parameter cgImage: The source CGImage
    /// - Returns: A Metal texture containing the image data
    /// - Note: Prefer createTexture(from: CVPixelBuffer) for VideoToolbox frames
    public func createTexture(from cgImage: CGImage) throws -> MTLTexture {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        let width = cgImage.width
        let height = cgImage.height
   //     print("width: \(width), height: \(height)")

        // Create a texture descriptor with proper alpha channel support
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,  // Change from bgra8Unorm to rgba8Unorm
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            logger.error("❌ Failed to create texture")
            throw MetalProcessorError.textureCreationFailed
        }

        // Create a bitmap context with proper alpha channel support
        let bytesPerRow = 4 * width
        let region = MTLRegionMake2D(0, 0, width, height)

        // Create a Core Graphics context with proper alpha channel support
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("❌ Failed to create CGContext")
            throw MetalProcessorError.contextCreationFailed
        }

        // Draw the image to the context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Copy the data to the texture
        if let data = context.data {
            texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        }

   //     logger.debug("✅ Created Metal texture: \(width)x\(height)")
        return texture
    }
    
    /// Create a CGImage from a Metal texture
    /// - Parameter texture: The source Metal texture
    /// - Returns: A CGImage containing the texture data
    public func createCGImage(from texture: MTLTexture) throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }
        
        let width = texture.width
        let height = texture.height
        let bytesPerRow = 4 * width
        let dataSize = bytesPerRow * height
        
        // Create a buffer to hold the pixel data
        var data = [UInt8](repeating: 0, count: dataSize)
        
        // Copy texture data to the buffer
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(&data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        // Create a data provider from the buffer
        guard let dataProvider = CGDataProvider(data: Data(bytes: &data, count: dataSize) as CFData) else {
            logger.error("❌ Failed to create data provider")
            throw MetalProcessorError.dataProviderCreationFailed
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
            logger.error("❌ Failed to create CGImage")
            throw MetalProcessorError.cgImageCreationFailed
        }
        
 //       logger.debug("✅ Created CGImage from texture: \(width)x\(height)")
        return cgImage
    }
    
    /// Scale a texture to a new size
    /// - Parameters:
    ///   - texture: The source texture
    ///   - size: The target size
    ///   - commandBuffer: Optional shared command buffer for batching operations
    /// - Returns: A new scaled texture
    public func scaleTexture(_ texture: MTLTexture, to size: CGSize, commandBuffer: MTLCommandBuffer? = nil) throws -> MTLTexture {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        // Create output texture
        // OPTIMIZATION: Use .private storage for GPU-only intermediate textures (2-3x faster)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private // GPU-only memory, faster than managed/shared

        guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            logger.error("❌ Failed to create output texture")
            throw MetalProcessorError.textureCreationFailed
        }

        // Use provided command buffer or create a new one
        let shouldCommit = commandBuffer == nil
        let cmdBuffer = commandBuffer ?? commandQueue.makeCommandBuffer()

        guard let cmdBuffer = cmdBuffer,
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            logger.error("❌ Failed to create command buffer or encoder")
            throw MetalProcessorError.commandBufferCreationFailed
        }

        encoder.setComputePipelineState(scalePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)

        // Calculate threadgroup size
        let threadgroupSize = calculateThreadgroupSize(pipeline: scalePipeline)
        let threadgroupCount = MTLSize(
            width: (outputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (outputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Only commit if we created the command buffer (not batching)
        if shouldCommit {
            cmdBuffer.commit()
        }

      //  logger.debug("✅ Scaled texture: \(texture.width)x\(texture.height) -> \(outputTexture.width)x\(outputTexture.height)")
        return outputTexture
    }
    
    /// Composite a texture onto another texture at a specific position
    /// - Parameters:
    ///   - sourceTexture: The source texture to composite
    ///   - destinationTexture: The destination texture
    ///   - position: The position to place the source texture
    ///   - commandBuffer: Optional shared command buffer for batching operations
    public func compositeTexture(
        _ sourceTexture: MTLTexture,
        onto destinationTexture: MTLTexture,
        at position: CGPoint,
        commandBuffer: MTLCommandBuffer? = nil
    ) throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        // Use provided command buffer or create a new one
        let shouldCommit = commandBuffer == nil
        let cmdBuffer = commandBuffer ?? commandQueue.makeCommandBuffer()

        guard let cmdBuffer = cmdBuffer,
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            logger.error("❌ Failed to create command buffer or encoder")
            throw MetalProcessorError.commandBufferCreationFailed
        }

        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)

        var positionValue = SIMD2<UInt32>(UInt32(position.x), UInt32(position.y))
        encoder.setBytes(&positionValue, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)

        // Calculate threadgroup size
        let threadgroupSize = calculateThreadgroupSize(pipeline: compositePipeline)
        let threadgroupCount = MTLSize(
            width: (sourceTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (sourceTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Only commit if we created the command buffer (not batching)
        if shouldCommit {
            cmdBuffer.commit()
        }

       // logger.debug("✅ Composited texture at position: (\(position.x), \(position.y))")
    }
    
    /// Create a new texture filled with a solid color
    /// - Parameters:
    ///   - size: The size of the texture
    ///   - color: The color to fill with (RGBA, 0.0-1.0)
    ///   - commandBuffer: Optional shared command buffer for batching operations
    /// - Returns: A new texture filled with the specified color
    public func createFilledTexture(size: CGSize, color: SIMD4<Float>, commandBuffer: MTLCommandBuffer? = nil) throws -> MTLTexture {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        // Create output texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            logger.error("❌ Failed to create output texture")
            throw MetalProcessorError.textureCreationFailed
        }

        // Use provided command buffer or create a new one
        let shouldCommit = commandBuffer == nil
        let cmdBuffer = commandBuffer ?? commandQueue.makeCommandBuffer()

        guard let cmdBuffer = cmdBuffer,
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            logger.error("❌ Failed to create command buffer or encoder")
            throw MetalProcessorError.commandBufferCreationFailed
        }

        encoder.setComputePipelineState(fillPipeline)
        encoder.setTexture(outputTexture, index: 0)

        var colorValue = color
        encoder.setBytes(&colorValue, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

        // Calculate threadgroup size
        let threadgroupSize = calculateThreadgroupSize(pipeline: fillPipeline)
        let threadgroupCount = MTLSize(
            width: (outputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (outputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Only commit if we created the command buffer (not batching)
        if shouldCommit {
            cmdBuffer.commit()
        }

       // logger.debug("✅ Created filled texture: \(outputTexture.width)x\(outputTexture.height)")
        return outputTexture
    }
    
    /// Add a border to a region of a texture
    /// - Parameters:
    ///   - texture: The texture to modify
    ///   - position: The position of the region
    ///   - size: The size of the region
    ///   - color: The border color (RGBA, 0.0-1.0)
    ///   - width: The border width in pixels
    ///   - commandBuffer: Optional shared command buffer for batching operations
    public func addBorder(
        to texture: MTLTexture,
        at position: CGPoint,
        size: CGSize,
        color: SIMD4<Float>,
        width: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }

        // Use provided command buffer or create a new one
        let shouldCommit = commandBuffer == nil
        let cmdBuffer = commandBuffer ?? commandQueue.makeCommandBuffer()

        guard let cmdBuffer = cmdBuffer,
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            logger.error("❌ Failed to create command buffer or encoder")
            throw MetalProcessorError.commandBufferCreationFailed
        }

        encoder.setComputePipelineState(borderPipeline)
        encoder.setTexture(texture, index: 0)

        var positionValue = SIMD2<UInt32>(UInt32(position.x), UInt32(position.y))
        var sizeValue = SIMD2<UInt32>(UInt32(size.width), UInt32(size.height))
        var colorValue = color
        var widthValue = width

        encoder.setBytes(&positionValue, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
        encoder.setBytes(&sizeValue, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
        encoder.setBytes(&colorValue, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        encoder.setBytes(&widthValue, length: MemoryLayout<Float>.size, index: 3)

        // Calculate threadgroup size
        let threadgroupSize = calculateThreadgroupSize(pipeline: borderPipeline)
        let threadgroupCount = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Only commit if we created the command buffer (not batching)
        if shouldCommit {
            cmdBuffer.commit()
        }

    //    logger.debug("✅ Added border at position: (\(position.x), \(position.y)), size: \(size.width)x\(size.height)")
    }

    private func saveDebugImage(_ image: CGImage, step: Int, description: String) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "step\(step)_\(timestamp)_\(description).jpg"
        let url = URL(filePath: "/Users/francois/Desktop/Test2").appendingPathComponent(filename)
        
        #if canImport(AppKit)
        let nsImage = NSImage(cgImage: image, size: .zero)
        if let data = nsImage.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url)
        }
        #elseif canImport(UIKit)
        let uiImage = UIImage(cgImage: image)
        if let data = uiImage.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url)
        }
        #endif
    }

    func processImagesToMTLTexture(images: [CGImage], maxColors: Int, outputSize: CGSize) -> MTLTexture? {
        guard !images.isEmpty else { return nil }
        
        // Step 1: Sample images
        let sampleCount = min(3, images.count)
        let step = max(1, images.count / sampleCount)
        let sampledImages = stride(from: 0, to: images.count, by: step).prefix(sampleCount).map { images[$0] }
        
        // Save sampled images
        for (_, image) in sampledImages.enumerated() {
          //  saveDebugImage(image, step: 1, description: "sampled_\(index)")
        }
        
        // Step 2: Extract dominant colors
        var allColors: [CGColor] = []
        let flags: [DominantColors.Options] = [
            .excludeBlack,     // Exclude pure black
            .excludeWhite,     // Exclude pure white
            .excludeGray       // Exclude pure gray
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

        // Step 3: Select top colors and create gradient
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
        let ctx = CGContext(
            data: nil,
            width: Int(outputSize.width * 1.01),
            height: Int(outputSize.height * 1.01),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        #endif
        //if the color array is empty, create a grey gradient
        if top3LightColors.isEmpty {
            let colorsArray: [CGColor] = [CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0), CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)]
            let cgColors = colorsArray as CFArray
            _ = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil)!
        } else {
            let colorsArray: [CGColor] = top3LightColors.map { $0 }
            let cgColors = colorsArray as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil)!
             #if os(macOS   )
            ctx!.drawLinearGradient(gradient,
                                    start: CGPoint.zero,
                                    end: CGPoint(x: outputSize.width * 1.01 , y: outputSize.height  * 1.01 ),
                                    options: [])
            #else
           // aaa
            #endif
        }
        #if os(iOS)
        gradientImage = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()
        #else
            ctx!.flush()
        gradientImage = ctx!.makeImage()
        #endif

        // Save gradient image
        if let gradientImage = gradientImage {
      //      saveDebugImage(gradientImage, step: 4, description: "gradient")
        }

        guard let imageForBlur = gradientImage else { return nil }

        // Step 5: Apply blur
        let ciImage = CIImage(cgImage: imageForBlur)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(12.0, forKey: kCIInputRadiusKey)
        guard let outputCI = blurFilter.outputImage else { return nil }

        let ciContext = CIContext()
        let cropped = outputCI.cropped(to: ciImage.extent)
        guard let blurredCG = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
        
        // Save blurred image
      //  saveDebugImage(blurredCG, step: 5, description: "blurred")
        do {
            let texture = try createTexture(from: blurredCG)
            return texture
        }catch {
            logger.error("❌ Failed to create texture: \(error.localizedDescription)")
            // in case of error, return a whote texture
            do {
                let texture = try createFilledTexture(size: outputSize, color: SIMD4<Float>(0.5, 0.5, 0.5, 1.0))
                return texture
            }catch {
                logger.error("❌ Failed to create filled texture: \(error.localizedDescription)")
                return nil
            }
            return nil
        }
        return nil
    }
    
        /*
        
        // Step 6: Create texture with proper error handling
        let textureLoader = MTKTextureLoader(device: device)
        do {
            // First try to create a texture with default options
            let texture = try textureLoader.newTexture(
                cgImage: blurredCG,
                options: [
                    .SRGB: false,
                    .generateMipmaps: false,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue as Any
                ]
            )
            
            // Verify texture creation
            guard texture.width > 0 && texture.height > 0 else {
                logger.error("❌ Created texture has invalid dimensions")
                return nil
            }
            
            return texture
        } catch {
            logger.error("❌ Failed to create texture: \(error.localizedDescription)")
            
            // Try alternative approach with different options
            do {
                let texture = try textureLoader.newTexture(
                    cgImage: blurredCG,
                    options: [
                        .SRGB: true,
                        .generateMipmaps: false,
                        .textureUsage: MTLTextureUsage.shaderRead.rawValue as Any
                    ]
                )
                return texture
            } catch {
                logger.error("❌ Alternative texture creation also failed: \(error.localizedDescription)")
                return nil
            }
        }
        */
    
    
    /// Generate a mosaic image using Metal acceleration
    /// - Parameters:
    ///   - frames: Array of frames with timestamps
    ///   - layout: Layout information
    ///   - metadata: Video metadata
    ///   - config: Mosaic configuration
    ///   - metadataHeader: Optional pre-generated metadata header image
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
      
        print("🎨 Starting Metal-accelerated mosaic generation - Frames: \(frames.count)")
        print("📐 Layout size: \(layout.mosaicSize.width)x\(layout.mosaicSize.height)")
        
        // Determine if we need space for the metadata header
        let hasMetadata = config.includeMetadata && metadataHeader != nil
        let metadataHeight = hasMetadata ? metadataHeader!.height : 0
        
        // Calculate adjusted mosaic size to accommodate metadata header
        var mosaicSize = layout.mosaicSize
        if hasMetadata {
            mosaicSize.height += CGFloat(metadataHeight)
    
        }
        // if for Iphone is true, use a light grey color for the mosaic
        var mosaicTexture: MTLTexture
        progressHandler?(0.1)
        if forIphone {
            let color = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
            let texture = try createFilledTexture(size: mosaicSize, color: color) 
            mosaicTexture = texture
        } else {
            guard let texture = try processImagesToMTLTexture(images: frames.map { $0.image }, maxColors: 5, outputSize: mosaicSize) else {
                throw MetalProcessorError.textureCreationFailed
            }
            mosaicTexture = texture
        }
        progressHandler?(0.2)
        // If we have a metadata header, composite it at the top of the mosaic
        if hasMetadata, let headerImage = metadataHeader {
            logger.debug("🏷️ Adding metadata header - Size: \(headerImage.width)×\(headerImage.height)")
            let headerTexture = try createTexture(from: headerImage)
            try compositeTexture(
                headerTexture,
                onto: mosaicTexture,
                at: CGPoint(x: 0, y: 0)
            )
        }
        
        // Process frames in batches to avoid GPU timeout
        // OPTIMIZATION: Use single command buffer per batch instead of per-operation
        let batchSize = 200
        let totalBatches = (frames.count + batchSize - 1) / batchSize
         progressHandler?(0.3)
        for batchStart in stride(from: 0, to: frames.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, frames.count)
            let batchFrames = frames[batchStart..<batchEnd]
            let currentBatch = batchStart / batchSize

            logger.debug("🔄 Processing batch \(currentBatch + 1)/\(totalBatches): frames \(batchStart+1)-\(batchEnd)")

            // Create a single command buffer for the entire batch
            guard let batchCommandBuffer = commandQueue.makeCommandBuffer() else {
                logger.error("❌ Failed to create batch command buffer")
                throw MetalProcessorError.commandBufferCreationFailed
            }

            for (index, frame) in batchFrames.enumerated() {
                let actualIndex = batchStart + index
                guard actualIndex < layout.positions.count else { break }

                let position = layout.positions[actualIndex]
                let size = layout.thumbnailSizes[actualIndex]

                // Adjust position to account for metadata header
                let adjustedY = position.y + (hasMetadata ? Int(metadataHeight) : 0)

                // Convert CGImage to Metal texture
                let frameTexture = try createTexture(from: frame.image)

                // Scale the frame if needed (using shared command buffer)
                let scaledTexture: MTLTexture
                if frameTexture.width != Int(size.width) || frameTexture.height != Int(size.height) {
                    scaledTexture = try scaleTexture(
                        frameTexture,
                        to: CGSize(width: size.width, height: size.height),
                        commandBuffer: batchCommandBuffer
                    )
                } else {
                    scaledTexture = frameTexture
                }

                // Composite the frame onto the mosaic at adjusted position (using shared command buffer)
                try compositeTexture(
                    scaledTexture,
                    onto: mosaicTexture,
                    at: CGPoint(x: position.x, y: adjustedY),
                    commandBuffer: batchCommandBuffer
                )

                // Update progress based on frame completion
                let frameProgress = 0.3 + ( 0.6 * Double(actualIndex + 1) / Double(frames.count))
                progressHandler?(frameProgress)

                if Task.isCancelled {
                    logger.warning("❌ Mosaic creation cancelled")
                    throw MetalProcessorError.cancelled
                }
            }

            // Commit the entire batch at once and wait for completion
            // OPTIMIZATION: Use await instead of waitUntilCompleted for async contexts
            batchCommandBuffer.commit()
            await batchCommandBuffer.completed()

            // Check for errors
            if batchCommandBuffer.status == .error {
                logger.error("❌ Batch command buffer execution failed")
                throw MetalProcessorError.commandBufferCreationFailed
            }
        }
        
        // Convert the Metal texture back to a CGImage
        progressHandler?(0.9)
        let cgImage = try createCGImage(from: mosaicTexture)
        
        let generationTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.debug("✅ Metal-accelerated mosaic generation complete - Size: \(cgImage.width)x\(cgImage.height) in \(generationTime) seconds")
        progressHandler?(1.0)
        return cgImage
    }

    /// Generate a mosaic image using Metal acceleration with streaming input
    /// - Parameters:
    ///   - stream: Async stream of frames (index, image)
    ///   - layout: Layout information
    ///   - metadata: Video metadata
    ///   - config: Mosaic configuration
    ///   - metadataHeader: Optional pre-generated metadata header image
    ///   - forIphone: Whether to optimize for iPhone
    ///   - progressHandler: Optional progress handler
    /// - Returns: Generated mosaic image
    public func generateMosaicStream(
        stream: AsyncThrowingStream<(Int, CGImage), Error>,
        layout: MosaicLayout,
        metadata: VideoMetadata,
        config: MosaicConfiguration,
        metadataHeader: CGImage? = nil,
        forIphone: Bool = false,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { trackPerformance(startTime: startTime) }
      
        logger.debug("🎨 Starting Streaming Metal-accelerated mosaic generation")
        logger.debug("📐 Layout size: \(layout.mosaicSize.width)x\(layout.mosaicSize.height)")
        
        // Determine if we need space for the metadata header
        let hasMetadata = config.includeMetadata && metadataHeader != nil
        let metadataHeight = hasMetadata ? metadataHeader!.height : 0
        
        // Calculate adjusted mosaic size to accommodate metadata header
        var mosaicSize = layout.mosaicSize
        if hasMetadata {
            mosaicSize.height += CGFloat(metadataHeight)
        }
        
        // Create mosaic texture
        var mosaicTexture: MTLTexture
        progressHandler?(0.1)
        if forIphone {
            let color = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
            mosaicTexture = try createFilledTexture(size: mosaicSize, color: color)
        } else {
             let color = SIMD4<Float>(0.1, 0.1, 0.1, 1.0)
             mosaicTexture = try createFilledTexture(size: mosaicSize, color: color)
        }
        
        progressHandler?(0.2)
        // If we have a metadata header, composite it at the top of the mosaic
        if hasMetadata, let headerImage = metadataHeader {
            logger.debug("🏷️ Adding metadata header - Size: \(headerImage.width)×\(headerImage.height)")
            let headerTexture = try createTexture(from: headerImage)
            try compositeTexture(
                headerTexture,
                onto: mosaicTexture,
                at: CGPoint(x: 0, y: 0)
            )
        }
        
        // Process frames in batches
        let batchSize = 20
        var batch: [(Int, CGImage)] = []
        var processedCount = 0
        let totalExpected = layout.positions.count
        
        for try await (index, image) in stream {
            batch.append((index, image))
            
            if batch.count >= batchSize {
                try processBatch(batch, into: mosaicTexture, layout: layout, hasMetadata: hasMetadata, metadataHeight: CGFloat(metadataHeight))
                processedCount += batch.count
                batch.removeAll()
                
                let progress = 0.2 + (0.7 * Double(processedCount) / Double(totalExpected))
                progressHandler?(progress)
            }
        }
        
        // Process remaining frames
        if !batch.isEmpty {
            try processBatch(batch, into: mosaicTexture, layout: layout, hasMetadata: hasMetadata, metadataHeight: CGFloat(metadataHeight))
            processedCount += batch.count
        }
        
        // Create CGImage from the final mosaic texture
        progressHandler?(0.95)
        let finalImage = try createCGImage(from: mosaicTexture)
        
        let generationTime = CFAbsoluteTimeGetCurrent() - startTime
        logger.debug("✅ Metal mosaic generation complete - Size: \(finalImage.width)x\(finalImage.height) in \(generationTime) seconds")
        progressHandler?(1.0)
        
        return finalImage
    }
    
    private func processBatch(
        _ batch: [(Int, CGImage)],
        into mosaicTexture: MTLTexture,
        layout: MosaicLayout,
        hasMetadata: Bool,
        metadataHeight: CGFloat
    ) throws {
        guard let batchCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalProcessorError.commandBufferCreationFailed
        }
        
        for (index, image) in batch {
            guard index < layout.positions.count else { continue }
            
            let position = layout.positions[index]
            let size = layout.thumbnailSizes[index]
            let adjustedY = position.y + (hasMetadata ? Int(metadataHeight) : 0)
            
            let frameTexture = try createTexture(from: image)
            
            let scaledTexture: MTLTexture
            if frameTexture.width != Int(size.width) || frameTexture.height != Int(size.height) {
                scaledTexture = try scaleTexture(
                    frameTexture,
                    to: CGSize(width: size.width, height: size.height),
                    commandBuffer: batchCommandBuffer
                )
            } else {
                scaledTexture = frameTexture
            }
            
            try compositeTexture(
                scaledTexture,
                onto: mosaicTexture,
                at: CGPoint(x: position.x, y: adjustedY),
                commandBuffer: batchCommandBuffer
            )
        }
        
        batchCommandBuffer.commit()
    }
    
    /// Get performance metrics for the Metal processor
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
    
    /// Calculate optimal threadgroup size for a given pipeline and texture dimensions
    /// - Parameters:
    ///   - pipeline: The compute pipeline state
    ///   - textureWidth: Optional texture width for adaptive sizing
    ///   - textureHeight: Optional texture height for adaptive sizing
    /// - Returns: Optimal threadgroup size
    private func calculateThreadgroupSize(
        pipeline: MTLComputePipelineState,
        textureWidth: Int? = nil,
        textureHeight: Int? = nil
    ) -> MTLSize {
        let threadExecutionWidth = pipeline.threadExecutionWidth

        // OPTIMIZATION: Adaptive threadgroup sizing based on texture dimensions
        // Use 16x16 as optimal for most operations, but adapt for small textures
        var width = min(16, threadExecutionWidth)
        var height = min(16, threadExecutionWidth)

        if let texWidth = textureWidth {
            width = min(width, texWidth)
        }
        if let texHeight = textureHeight {
            height = min(height, texHeight)
        }

        // Ensure we don't exceed pipeline limits
        let maxThreadsPerThreadgroup = pipeline.maxTotalThreadsPerThreadgroup
        let totalThreads = width * height
        if totalThreads > maxThreadsPerThreadgroup {
            // Scale down proportionally
            let scale = sqrt(Double(maxThreadsPerThreadgroup) / Double(totalThreads))
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }

        return MTLSize(width: width, height: height, depth: 1)
    }
    
    private func trackPerformance(startTime: CFAbsoluteTime) {
        let executionTime = CFAbsoluteTimeGetCurrent() - startTime
        lastExecutionTime = executionTime
        totalExecutionTime += executionTime
        operationCount += 1
    }
    
    private func formatMetadata(_ metadata: VideoMetadata) -> String {
        var lines: [String] = []
        
        if let codec = metadata.codec {
            lines.append("Codec: \(codec)")
        }
        
        if let bitrate = metadata.bitrate {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB]
            formatter.countStyle = .binary
            lines.append("Bitrate: \(formatter.string(fromByteCount: bitrate))/s")
        }
        
        for (key, value) in metadata.custom {
            lines.append("\(key): \(value)")
        }
        
        return lines.joined(separator: " | ")
    }
    
    // Timestamp is now handled directly in ThumbnailProcessor
    
    // Metadata functionality is now handled in ThumbnailProcessor
}

// MARK: - Errors

/// Errors that can occur during Metal processing
public enum MetalProcessorError: Error {
    case deviceNotAvailable
    case commandQueueCreationFailed
    case libraryCreationFailed
    case textureCacheCreationFailed
    case functionNotFound
    case pipelineCreationFailed
    case textureCreationFailed
    case contextCreationFailed
    case commandBufferCreationFailed
    case dataProviderCreationFailed
    case cgImageCreationFailed
    case cancelled
} 

#if canImport(AppKit)
private extension NSImage {
    func pngData() -> Data? {
        guard let tiffRepresentation = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }
    
    func jpegData(compressionQuality: Double = 0.8) -> Data? {
        guard let tiffRepresentation = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .jpeg,
                                        properties: [.compressionFactor: compressionQuality])
    }
}
#elseif canImport(UIKit)
// Adjust the usage in the code above to directly call the built-in UIImage method with CGFloat
// No extension needed for UIImage as it already has pngData() and jpegData(compressionQuality:) methods
#endif
