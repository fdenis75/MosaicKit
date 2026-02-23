import Foundation
import CoreGraphics

/// Configuration for mosaic layout settings.
public struct LayoutConfiguration: Codable, Sendable {
    /// The aspect ratio of the mosaic (e.g., 16:9, 4:3).
    public var aspectRatio: AspectRatio

    /// The spacing between frames in pixels.
    public var spacing: CGFloat

    /// The type of layout to use.
    public var layoutType: LayoutType

    /// Visual settings for the layout.
    public var visual: VisualSettings

    /// Creates a new LayoutConfiguration instance.
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

/// Available layout types for mosaic generation.
public enum LayoutType: String, Codable, Sendable {
    /// Auto layout based on screen size and content.
    case auto
    /// Custom layout with specific density and arrangement.
    case custom
    /// Dynamic layout with center emphasis.
    case dynamic
    /// Classic grid layout.
    case classic
    /// Layout optimized for iPhone screens.
    case iphone
}

/// Predefined aspect ratios for mosaic layout.
public enum AspectRatio: String, Codable, Sendable {
    /// 16:9 aspect ratio (widescreen)
    case widescreen = "16:9"
    /// 4:3 aspect ratio (standard)
    case standard = "4:3"
    /// 1:1 aspect ratio (square)
    case square = "1:1"
    /// 21:9 aspect ratio (ultrawide)
    case ultrawide = "21:9"
    /// 9:16 aspect ratio (vertical/portrait)
    case vertical = "9:16"

    /// Get the actual ratio value
    public var ratio: CGFloat {
        switch self {
        case .widescreen: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .square: return 1.0
        case .ultrawide: return 21.0 / 9.0
        case .vertical: return 9.0 / 16.0
        }
    }
    
    public static func findNearest(to: CGSize) -> AspectRatio {
        let targetRatio = to.width / to.height
        return Self.allCases.min(by: {
            let a = $0.ratio
            let b = $1.ratio
            return abs(a - targetRatio) < abs(b - targetRatio)
        })!
    }

    /// All available aspect ratios
    public static let allCases: [AspectRatio] = [.widescreen, .standard, .square, .ultrawide, .vertical]
}

/// Visual settings for mosaic layout.
public struct VisualSettings: Codable, Sendable {
    /// Whether to add borders around frames.
    public var addBorder: Bool

    /// The border color.
    public var borderColor: BorderColor

    /// The border width in pixels.
    public var borderWidth: CGFloat

    /// Whether to add shadow to frames.
    public var addShadow: Bool

    /// Shadow settings if enabled.
    public var shadowSettings: ShadowSettings?

    /// Creates a new VisualSettings instance.
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

/// Border color options.
public enum BorderColor: String, Codable, Sendable {
    case white
    case black
    case gray

    /// Returns the grayscale intensity (0.0–1.0) for this color. The `opacity` parameter is ignored.
    public func withOpacity(_ opacity: CGFloat) -> CGFloat {
        switch self {
        case .white: return 1.0
        case .black: return 0.0
        case .gray: return 0.5
        }
    }
}

/// Shadow settings for frames.
public struct ShadowSettings: Codable, Sendable {
    /// The shadow opacity (0.0 to 1.0).
    public let opacity: CGFloat

    /// The shadow radius in pixels.
    public let radius: CGFloat

    /// The shadow offset.
    public let offset: CGSize

    /// Creates a new ShadowSettings instance.
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

