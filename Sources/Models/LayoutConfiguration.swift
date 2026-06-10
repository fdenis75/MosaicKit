import Foundation
import CoreGraphics

/// A structure that defines the configuration for video mosaic layout settings.
public struct LayoutConfiguration: Codable, Sendable {
    /// The aspect ratio of the mosaic (e.g., 16:9, 4:3).
    public var aspectRatio: AspectRatio

    /// The spacing between frames in pixels.
    public var spacing: CGFloat

    /// The type of layout to use.
    public var layoutType: LayoutType

    /// The visual settings for the layout.
    public var visual: VisualSettings

    /// Creates a new layout configuration with the specified settings.
    ///
    /// - Parameters:
    ///   - aspectRatio: The target aspect ratio of the mosaic.
    ///   - spacing: The spacing in pixels between thumbnails.
    ///   - layoutType: The layout algorithm to apply.
    ///   - visual: Visual enhancements like borders and shadows.
    public init(
        aspectRatio: AspectRatio = .widescreen,
        spacing: CGFloat = 4,
        layoutType: LayoutType = .custom,
        visual: VisualSettings = .default
    ) {
        self.aspectRatio = aspectRatio
        self.spacing = spacing
        self.layoutType = layoutType
        self.visual = visual
    }

   
    /// The default layout configuration.
    public static let `default` = LayoutConfiguration()
}

/// An enumeration representing the available layout types for video mosaic generation.
public enum LayoutType: String, Codable, Sendable {
    /// An automatic layout based on screen size and content.
    case auto
    /// A custom layout with specific zone-based arrangements.
    case custom
    /// A dynamic layout emphasizing center frames.
    case dynamic
    /// A classic uniform grid layout.
    case classic
    /// A layout optimized for portrait iPhone screens.
    case iphone
    
    /// An array of all available layout types.
    public static let allCases: [LayoutType] = [.auto, .custom, .dynamic, .classic, .iphone]
}

/// An enumeration representing the predefined aspect ratios for a mosaic layout.
public enum AspectRatio: String, Codable, Sendable {
    /// A 16:9 widescreen aspect ratio.
    case widescreen = "16:9"
    /// A 4:3 standard television/monitor aspect ratio.
    case standard = "4:3"
    /// A 1:1 square aspect ratio.
    case square = "1:1"
    /// A 21:9 ultrawide cinematic aspect ratio.
    case ultrawide = "21:9"
    /// A 9:16 vertical/portrait aspect ratio.
    case vertical = "9:16"

    /// The numerical value of the aspect ratio (width divided by height).
    public var ratio: CGFloat {
        switch self {
        case .widescreen: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .square: return 1.0
        case .ultrawide: return 21.0 / 9.0
        case .vertical: return 9.0 / 16.0
        }
    }
    
    /// Finds the nearest predefined aspect ratio for a given size.
    ///
    /// - Parameter to: The target dimensions.
    /// - Returns: The closest predefined aspect ratio.
    public static func findNearest(to: CGSize) -> AspectRatio {
        let targetRatio = to.width / to.height
        return Self.allCases.min(by: {
            let a = $0.ratio
            let b = $1.ratio
            return abs(a - targetRatio) < abs(b - targetRatio)
        })!
    }

    /// An array of all available aspect ratios.
    public static let allCases: [AspectRatio] = [.widescreen, .standard, .square, .ultrawide, .vertical]
}

/// A structure that defines the visual settings for a mosaic layout.
public struct VisualSettings: Codable, Sendable {
    /// A boolean value indicating whether to add borders around thumbnails.
    public var addBorder: Bool

    /// The border color configuration.
    public var borderColor: BorderColor

    /// The border width in pixels.
    public var borderWidth: CGFloat

    /// A boolean value indicating whether to apply shadows to thumbnails.
    public var addShadow: Bool

    /// The shadow settings used if shadow drawing is enabled.
    public var shadowSettings: ShadowSettings?

    /// Creates a new visual settings configuration with the specified properties.
    ///
    /// - Parameters:
    ///   - addBorder: Whether to draw borders.
    ///   - borderColor: The color of the borders.
    ///   - borderWidth: The width of the borders in pixels.
    ///   - addShadow: Whether to draw shadows.
    ///   - shadowSettings: The configuration for the shadows, or `nil` to use default shadow settings.
    public init(
        addBorder: Bool = false,
        borderColor: BorderColor = .white,
        borderWidth: CGFloat = 1,
        addShadow: Bool = true,
        shadowSettings: ShadowSettings? = .default
    ) {
        self.addBorder = addBorder
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.addShadow = addShadow
        self.shadowSettings = shadowSettings
    }

    /// The default visual settings.
    public static let `default` = VisualSettings()
}

/// An enumeration representing the available border color options.
public enum BorderColor: String, Codable, Sendable {
    /// A white border.
    case white
    /// A black border.
    case black
    /// A gray border.
    case gray

    /// Returns the grayscale intensity (0.0 to 1.0) for this color.
    ///
    /// - Parameter opacity: The target opacity (ignored in the current implementation).
    /// - Returns: A `CGFloat` representing the grayscale value.
    public func withOpacity(_ opacity: CGFloat) -> CGFloat {
        switch self {
        case .white: return 1.0
        case .black: return 0.0
        case .gray: return 0.5
        }
    }
}

/// A structure that defines the shadow settings for mosaic frames.
public struct ShadowSettings: Codable, Sendable {
    /// The shadow opacity (ranging from 0.0 to 1.0).
    public let opacity: CGFloat

    /// The shadow blur radius in pixels.
    public let radius: CGFloat

    /// The offset of the shadow relative to the thumbnail frame.
    public let offset: CGSize

    /// Creates a new shadow configuration with the specified parameters.
    ///
    /// - Parameters:
    ///   - opacity: The opacity of the shadow.
    ///   - radius: The blur radius in pixels.
    ///   - offset: The directional offset of the shadow.
    public init(
        opacity: CGFloat = 0.5,
        radius: CGFloat = 4,
        offset: CGSize = CGSize(width: 0, height: -2)
    ) {
        self.opacity = opacity
        self.radius = radius
        self.offset = offset
    }

    /// The default shadow settings.
    public static let `default` = ShadowSettings()
}

