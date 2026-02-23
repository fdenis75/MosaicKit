import Foundation
#if os(macOS)
import Metal
#endif
import OSLog


/// A factory for creating mosaic generators with platform-specific implementations
// @available(macOS 26, iOS 26, *)
public enum MosaicGeneratorFactory {
    /// The type of mosaic generator to create
    public enum GeneratorType: String, Codable {
        /// Metal-accelerated mosaic generator (macOS)
        case metal = "Metal"
        /// Core Graphics-accelerated mosaic generator (iOS)
        case coreGraphics = "CoreGraphics"

        public init?(rawValue: String) {
            switch rawValue {
            case "Metal": self = .metal
            case "CoreGraphics": self = .coreGraphics
            default: return nil
            }
        }
    }

    /// Preference for which generator implementation to use
    public enum GeneratorPreference {
        /// Automatically select based on platform (Metal for macOS, Core Graphics for iOS)
        case auto
        /// Prefer Metal implementation (requires Metal support on macOS)
        case preferMetal
        /// Prefer Core Graphics implementation (available on both platforms)
        case preferCoreGraphics
    }

    private static let logger = Logger(subsystem: "com.mosaicKit", category: "mosaic-factory")

    /// Create a mosaic generator with default platform preference
    /// - Returns: A platform-appropriate mosaic generator
    public static func createGenerator() throws -> any MosaicGeneratorProtocol {
        return try createGenerator(preference: .auto)
    }

    /// Create a mosaic generator with specified preference
    /// - Parameter preference: The preferred generator implementation
    /// - Returns: A mosaic generator matching the preference
    public static func createGenerator(preference: GeneratorPreference) throws -> any MosaicGeneratorProtocol {
        switch preference {
        case .auto:
            #if os(macOS)
            logger.debug("🔧 Auto-selecting Metal generator for macOS")
            return try createMetalGenerator()
            #elseif os(iOS)
            logger.debug("🔧 Auto-selecting Core Graphics generator for iOS")
            return try createCoreGraphicsGenerator()
            #endif

        case .preferMetal:
            #if os(macOS)
            logger.debug("🔧 Creating Metal generator (preferred)")
            return try createMetalGenerator()
            #else
            logger.warning("⚠️ Metal not available on iOS, falling back to Core Graphics")
            return try createCoreGraphicsGenerator()
            #endif

        case .preferCoreGraphics:
            logger.debug("🔧 Creating Core Graphics generator (preferred)")
            return try createCoreGraphicsGenerator()
        }
    }

    #if os(macOS)
    /// Create a Metal-accelerated generator (macOS specific)
    private static func createMetalGenerator() throws -> MetalMosaicGenerator {
        guard MTLCreateSystemDefaultDevice() != nil else {
            logger.error("❌ Metal not available, cannot create Metal generator")
            throw MosaicError.metalNotSupported
        }
        return try MetalMosaicGenerator()
    }
    #endif

    /// Create a Core Graphics-accelerated generator (available on both platforms)
    private static func createCoreGraphicsGenerator() throws -> CoreGraphicsMosaicGenerator {
        return try CoreGraphicsMosaicGenerator()
    }
    
    #if os(macOS)
    /// Perform detailed assessment of Metal capabilities (macOS only)
    /// - Returns: A tuple containing a boolean recommendation and reason string
    private static func assessMetalCapabilities() -> (shouldUseMetal: Bool, reason: String) {
        // Check for basic Metal availability
        guard let device = MTLCreateSystemDefaultDevice() else {
            return (false, "Metal is not available on this system")
        }

        // Architecture check
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif

        // Check device properties
        let deviceName = device.name
        let isLowPower = device.isLowPower
        let hasUnifiedMemory = device.hasUnifiedMemory
        let supportsFamilyMac2 = device.supportsFamily(.mac2)

        // Memory check
        let systemMemory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Double(systemMemory) / 1_073_741_824.0 // Convert to GB
        let hasAdequateMemory = memoryGB >= 8.0

        // Other system info
        let processorCount = ProcessInfo.processInfo.processorCount
        let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount

        // Log detailed hardware information for debugging
        logger.debug("""
        🔍 Hardware assessment:
        - Device: \(deviceName)
        - Architecture: \(isAppleSilicon ? "Apple Silicon" : "Intel")
        - Memory: \(String(format: "%.1f", memoryGB)) GB
        - Processors: \(processorCount) (\(activeProcessorCount) active)
        - Low Power: \(isLowPower)
        - Unified Memory: \(hasUnifiedMemory)
        - Supports Mac2 Family: \(supportsFamilyMac2)
        """)

        // Decision logic - prioritize Apple Silicon and modern GPUs
        if isAppleSilicon {
            return (true, "Apple Silicon detected with unified memory architecture")
        }

        // Check Intel Macs with dedicated GPUs
        if !isLowPower && hasAdequateMemory && deviceName.contains("Radeon") {
            return (true, "Intel Mac with dedicated AMD GPU detected")
        }

        if !isLowPower && hasAdequateMemory && deviceName.contains("GeForce") {
            return (true, "Intel Mac with dedicated NVIDIA GPU detected")
        }

        // For other configurations, be conservative
        if hasAdequateMemory && supportsFamilyMac2 {
            return (true, "System has adequate memory and supports Metal family Mac2")
        }

        // Default to CPU rendering for other configurations
        return (false, "System better suited for CPU rendering")
    }

    /// Check if Metal is available on this system (macOS only)
    /// - Returns: True if Metal is available
    private static func isMetalAvailable() -> Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }
    #endif

    /// Check if we're running on Apple Silicon
    /// - Returns: True if running on Apple Silicon
    private static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Get information about the available mosaic generators
    /// - Returns: A dictionary with information about the available generators
    public static func getGeneratorInfo() -> [String: Any] {
        var info: [String: Any] = [:]

        // System information
        info["isAppleSilicon"] = isAppleSilicon()

        #if os(macOS)
        info["platform"] = "macOS"
        info["isMetalAvailable"] = isMetalAvailable()

        // Available generators
        info["availableGenerators"] = [
            "metal": isMetalAvailable()
        ]

        // Recommended generator
        if isMetalAvailable() && isAppleSilicon() {
            info["recommendedGenerator"] = "metal"
        } else {
            info["recommendedGenerator"] = "metal"
        }
        #elseif os(iOS)
        info["platform"] = "iOS"
        info["isCoreGraphicsAvailable"] = true

        // Available generators
        info["availableGenerators"] = [
            "coreGraphics": true
        ]

        // Recommended generator for iOS is always Core Graphics
        info["recommendedGenerator"] = "coreGraphics"
        #endif

        return info
    }
} 
