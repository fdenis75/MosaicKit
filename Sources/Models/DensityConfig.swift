import Foundation

/// Density configuration for frame extraction in mosaic generation.
///
/// Density determines how many frames are extracted from the video:
/// - Lower factor = fewer frames (e.g., XXL = 0.25)
/// - Higher factor = more frames (e.g., XXS = 4.0)
public struct DensityConfig: Equatable, Hashable, Codable, Sendable {
    /// The display name of the density level
    public let name: String

    /// The factor used to calculate thumbnail count
    public let factor: Double

    /// Multiplier for frame extraction (affects how many frames are extracted vs shown)
    public let extractsMultiplier: Double

    /// Human-readable description of the thumbnail count
    public let thumbnailCountDescription: String

    // MARK: - Codable
    private enum CodingKeys: String, CodingKey {
        case factor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(factor, forKey: .factor)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let factor = try container.decode(Double.self, forKey: .factor)

        // Find the matching case based on factor
        if let config = DensityConfig.allCases.first(where: { $0.factor == factor }) {
            self = config
        } else {
            // Default to .m if no match found
            self = .m
        }
    }

    public init(name: String, factor: Double, extractsMultiplier: Double, thumbnailCountDescription: String) {
        self.name = name
        self.factor = factor
        self.extractsMultiplier = extractsMultiplier
        self.thumbnailCountDescription = thumbnailCountDescription
    }

    // MARK: - Predefined Densities

    /// Minimal density - fewest frames
    public static let xxl = DensityConfig(name: "XXL", factor: 0.25, extractsMultiplier: 0.125, thumbnailCountDescription: "minimal")

    /// Low density
    public static let xl = DensityConfig(name: "XL", factor: 0.5, extractsMultiplier: 0.25, thumbnailCountDescription: "low")

    /// Medium density
    public static let l = DensityConfig(name: "L", factor: 0.75, extractsMultiplier: 0.5, thumbnailCountDescription: "medium")

    /// High density (default)
    public static let m = DensityConfig(name: "M", factor: 1.0, extractsMultiplier: 1.0, thumbnailCountDescription: "high")

    /// Very high density
    public static let s = DensityConfig(name: "S", factor: 2.0, extractsMultiplier: 2.0, thumbnailCountDescription: "very high")

    /// Super high density
    public static let xs = DensityConfig(name: "XS", factor: 3.0, extractsMultiplier: 4.0, thumbnailCountDescription: "super high")

    /// Maximal density - most frames
    public static let xxs = DensityConfig(name: "XXS", factor: 4.0, extractsMultiplier: 8.0, thumbnailCountDescription: "maximal")

    /// All available density configurations
    public static let allCases = [xxl, xl, l, m, s, xs, xxs]

    /// Default density configuration (high)
    public static let `default` = m
}
