import Foundation
import Metal
import OSLog

/// A factory for creating mosaic generators backed by Metal GPU acceleration
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

    /// Preference for which generator implementation to use
    public enum GeneratorPreference {
        /// Automatically select the best available generator (Metal)
        case auto
        /// Prefer Metal implementation
        case preferMetal
    }

    private static let logger = Logger(subsystem: "com.mosaicKit", category: "mosaic-factory")

    /// Create a mosaic generator with default platform preference
    public static func createGenerator() throws -> any MosaicGeneratorProtocol {
        return try createGenerator(preference: .auto)
    }

    /// Create a mosaic generator with specified preference
    public static func createGenerator(preference: GeneratorPreference) throws -> any MosaicGeneratorProtocol {
        switch preference {
        case .auto, .preferMetal:
            logger.debug("🔧 Creating Metal generator")
            return try createMetalGenerator()
        }
    }

    private static func createMetalGenerator() throws -> MetalMosaicGenerator {
        guard MTLCreateSystemDefaultDevice() != nil else {
            logger.error("❌ Metal not available on this device")
            throw MosaicError.metalNotSupported
        }
        return try MetalMosaicGenerator()
    }

    /// Assess Metal capabilities on the current device
    private static func assessMetalCapabilities() -> (shouldUseMetal: Bool, reason: String) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return (false, "Metal is not available on this device")
        }

        let deviceName = device.name
        let hasUnifiedMemory = device.hasUnifiedMemory

        logger.debug("🔍 Metal device: \(deviceName), unified memory: \(hasUnifiedMemory)")

        #if arch(arm64)
        return (true, "ARM64 device with unified memory architecture")
        #else
        let isLowPower = device.isLowPower
        let hasAdequateMemory = ProcessInfo.processInfo.physicalMemory >= 8_589_934_592
        if !isLowPower && hasAdequateMemory {
            return (true, "Intel Mac with adequate GPU resources")
        }
        return (false, "Intel Mac with insufficient GPU resources")
        #endif
    }

    /// Check if Metal is available on this device
    public static func isMetalAvailable() -> Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }

    /// Get information about the available mosaic generators
    public static func getGeneratorInfo() -> [String: Any] {
        var info: [String: Any] = [:]

        #if arch(arm64)
        info["architecture"] = "arm64"
        #else
        info["architecture"] = "x86_64"
        #endif

        info["isMetalAvailable"] = isMetalAvailable()
        info["availableGenerators"] = ["metal": isMetalAvailable()]
        info["recommendedGenerator"] = "metal"

        if let device = MTLCreateSystemDefaultDevice() {
            info["metalDeviceName"] = device.name
            info["hasUnifiedMemory"] = device.hasUnifiedMemory
        }

        return info
    }
}
