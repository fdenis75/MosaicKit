import Foundation
import Metal
import OSLog


/// A factory for creating mosaic generators
@available(macOS 15, iOS 18, *)
public enum MosaicGeneratorFactory {
    /// The type of mosaic generator to create
    public enum GeneratorType: String, Codable {
        /// Metal-accelerated mosaic generator
        case metal = "Metal"
        
        public init?(rawValue: String) {
            switch rawValue {
            case "Metal": self = .metal
            default: return nil
            }
        }
    }
    
    private static let logger = Logger(subsystem: "com.hypermovie", category: "mosaic-factory")
    
    /// Create a mosaic generator
    /// - Returns: A mosaic generator
    public static func createGenerator() throws -> MetalMosaicGenerator {
        logger.debug("🔧 Creating Metal-accelerated mosaic generator")
        return try MetalMosaicGenerator()
    }
    
    /// Perform detailed assessment of Metal capabilities
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
        #if os(iOS)
        let isLowPower = false
        #else
        let isLowPower = device.isLowPower

        #endif
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
    
    /// Check if Metal is available on this system
    /// - Returns: True if Metal is available
    private static func isMetalAvailable() -> Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }
    
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
        info["isMetalAvailable"] = isMetalAvailable()
        
        // Available generators
        info["availableGenerators"] = [
            "standard": false,
            "metal": isMetalAvailable()
        ]
        
        // Recommended generator
        if isMetalAvailable() && isAppleSilicon() {
            info["recommendedGenerator"] = "metal"
        } else {
            info["recommendedGenerator"] = "standard"
        }
        
        return info
    }
} 
