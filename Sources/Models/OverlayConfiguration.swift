import Foundation
import CoreGraphics

// MARK: - Frame Label (2a)

/// The content shown in the per-frame label pill.
public enum FrameLabelFormat: String, Codable, Sendable {
    /// HH:MM:SS timestamp — the original hardcoded behaviour.
    case timestamp
    /// Sequential frame index, e.g. "Frame 42".
    case frameIndex
    /// No text; visual treatment (rounded corners, vignette) is still applied.
    case none
}

/// Anchor position for the per-frame label inside each thumbnail.
public enum FrameLabelPosition: String, Codable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    /// Bottom-right — the original hardcoded position.
    case bottomRight
    case center
}

/// Background style behind the per-frame label text.
public enum FrameLabelBackground: String, Codable, Sendable {
    /// Dark pill with gradient — the original style.
    case pill
    /// No background; text only (shadow retained for legibility).
    case none
    /// Full-width translucent bar spanning the thumbnail edge nearest the label position.
    case fullWidth
}

/// Configuration for the per-frame label drawn on each thumbnail.
public struct FrameLabelConfig: Codable, Sendable {
    /// Draw a label on each thumbnail.
    public var show: Bool
    /// What text to display.
    public var format: FrameLabelFormat
    /// Where the label is anchored inside the thumbnail.
    public var position: FrameLabelPosition
    /// Label text colour. Defaults to white.
    public var textColor: MosaicColor
    /// Background style.
    public var backgroundStyle: FrameLabelBackground

    public init(
        show: Bool = true,
        format: FrameLabelFormat = .timestamp,
        position: FrameLabelPosition = .bottomRight,
        textColor: MosaicColor = MosaicColor(red: 1, green: 1, blue: 1),
        backgroundStyle: FrameLabelBackground = .pill
    ) {
        self.show = show
        self.format = format
        self.position = position
        self.textColor = textColor
        self.backgroundStyle = backgroundStyle
    }

    /// Mirrors the original hardcoded appearance.
    public static let `default` = FrameLabelConfig()
}

// MARK: - Header / Metadata (2b)

/// Height rule for the metadata header band.
public enum HeaderHeight: Codable, Sendable, Equatable {
    /// 50 % of the first thumbnail row height — the original calculation.
    case auto
    /// An exact pixel height.
    case fixed(Int)

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "fixed": self = .fixed(try c.decode(Int.self, forKey: .value))
        default:      self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try c.encode("auto", forKey: .type)
        case .fixed(let v):
            try c.encode("fixed", forKey: .type)
            try c.encode(v, forKey: .value)
        }
    }
}

/// A single piece of information shown in the header band.
public enum MetadataField: Codable, Sendable, Equatable {
    /// Video title.
    case title
    /// Formatted duration ("HH:MM:SS").
    case duration
    /// Human-readable file size ("1.2 GB").
    case fileSize
    /// Pixel resolution ("1920×1080").
    case resolution
    /// Video codec string.
    case codec
    /// Formatted bitrate ("8.5 Mb/s").
    case bitrate
    /// Frame rate ("29.97 fps").
    case frameRate
    /// Full file path.
    case filePath
    /// A row of colour swatches sampled from the video's dominant colours.
    case colorPalette(swatchCount: Int)
    /// Arbitrary user-defined label/value pair.
    case custom(label: String, value: String)

    private enum CodingKeys: String, CodingKey { case type, label, value, swatchCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "title":        self = .title
        case "duration":     self = .duration
        case "fileSize":     self = .fileSize
        case "resolution":   self = .resolution
        case "codec":        self = .codec
        case "bitrate":      self = .bitrate
        case "frameRate":    self = .frameRate
        case "filePath":     self = .filePath
        case "colorPalette": self = .colorPalette(swatchCount: try c.decode(Int.self, forKey: .swatchCount))
        default:
            self = .custom(
                label: try c.decode(String.self, forKey: .label),
                value: try c.decode(String.self, forKey: .value)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .title:        try c.encode("title",        forKey: .type)
        case .duration:     try c.encode("duration",     forKey: .type)
        case .fileSize:     try c.encode("fileSize",     forKey: .type)
        case .resolution:   try c.encode("resolution",   forKey: .type)
        case .codec:        try c.encode("codec",        forKey: .type)
        case .bitrate:      try c.encode("bitrate",      forKey: .type)
        case .frameRate:    try c.encode("frameRate",    forKey: .type)
        case .filePath:     try c.encode("filePath",     forKey: .type)
        case .colorPalette(let n):
            try c.encode("colorPalette", forKey: .type)
            try c.encode(n, forKey: .swatchCount)
        case .custom(let lbl, let val):
            try c.encode("custom", forKey: .type)
            try c.encode(lbl, forKey: .label)
            try c.encode(val, forKey: .value)
        }
    }
}

/// Configuration for the top metadata header band.
public struct HeaderConfig: Codable, Sendable {
    /// Ordered fields to render. Defaults reproduce the original two hardcoded rows.
    public var fields: [MetadataField]
    /// Band height rule.
    public var height: HeaderHeight
    /// Text colour override. `nil` → platform default (black on macOS, white on iOS / forIphone).
    public var textColor: MosaicColor?
    /// Background fill override. `nil` → semi-transparent dark default.
    public var backgroundColor: MosaicColor?

    public init(
        fields: [MetadataField] = [.title, .duration, .fileSize, .codec, .resolution, .bitrate, .filePath],
        height: HeaderHeight = .auto,
        textColor: MosaicColor? = nil,
        backgroundColor: MosaicColor? = nil
    ) {
        self.fields = fields
        self.height = height
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }

    /// Reproduces the original hardcoded header appearance.
    public static let `default` = HeaderConfig()
}

// MARK: - Watermark (2c)

/// The visual content of a watermark layer.
public enum WatermarkContent: Codable, Sendable {
    /// Plain text drawn with the system font.
    case text(String)
    /// An image loaded from the given URL.
    case image(URL)

    private enum CodingKeys: String, CodingKey { case type, text, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "image": self = .image(try c.decode(URL.self, forKey: .url))
        default:      self = .text(try c.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .image(let u):
            try c.encode("image", forKey: .type)
            try c.encode(u, forKey: .url)
        }
    }
}

/// Anchor corner for the watermark on the final mosaic.
public enum WatermarkPosition: String, Codable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center
}

/// Configuration for an optional watermark / branding layer applied to the final mosaic.
public struct WatermarkConfig: Codable, Sendable {
    /// What to draw.
    public var content: WatermarkContent
    /// Where to place it.
    public var position: WatermarkPosition
    /// Opacity in 0.0–1.0.
    public var opacity: Double
    /// Width of the watermark as a fraction of the mosaic width (e.g. 0.12 = 12 %).
    public var scale: Double

    public init(
        content: WatermarkContent,
        position: WatermarkPosition = .bottomRight,
        opacity: Double = 0.35,
        scale: Double = 0.12
    ) {
        self.content = content
        self.position = position
        self.opacity = min(max(opacity, 0), 1)
        self.scale = min(max(scale, 0.01), 1)
    }
}

// MARK: - Color DNA (2d)

/// Where the Color DNA strip is placed relative to the assembled mosaic.
public enum ColorDNAPosition: String, Codable, Sendable {
    /// Above the header (or above the mosaic content when no header is present).
    case top
    /// Below all content.
    case bottom
}

/// Rendering style for the Color DNA strip.
public enum ColorDNAStyle: String, Codable, Sendable {
    /// Hard-edged colour columns — classic MovieBarcode look.
    case barcode
    /// Smooth linear gradient between consecutive frame colours.
    case gradient
}

/// Configuration for the Color DNA strip: a thin band where each column shows one frame's dominant colour.
public struct ColorDNAConfig: Codable, Sendable {
    /// Draw the strip.
    public var show: Bool
    /// Height of the strip in pixels.
    public var height: CGFloat
    /// Where to attach the strip.
    public var position: ColorDNAPosition
    /// Rendering style.
    public var style: ColorDNAStyle

    public init(
        show: Bool = false,
        height: CGFloat = 24,
        position: ColorDNAPosition = .bottom,
        style: ColorDNAStyle = .barcode
    ) {
        self.show = show
        self.height = max(8, height)
        self.position = position
        self.style = style
    }

    /// Default: hidden, 24 px tall, bottom, barcode style.
    public static let `default` = ColorDNAConfig()
}

// MARK: - Umbrella

/// Umbrella configuration for all overlay and annotation layers.
///
/// Pass this via `MosaicConfiguration.overlay`. All properties default to the
/// original hardcoded behaviour so existing code requires no changes.
public struct OverlayConfiguration: Codable, Sendable {
    /// Per-frame label (timestamp / frame-index pill drawn on each thumbnail).
    public var frameLabel: FrameLabelConfig
    /// Top metadata header band customisation. The band is only shown when
    /// `MosaicConfiguration.includeMetadata` is `true`.
    public var header: HeaderConfig
    /// Optional watermark drawn on the assembled mosaic image.
    public var watermark: WatermarkConfig?
    /// Color DNA strip.
    public var colorDNA: ColorDNAConfig

    public init(
        frameLabel: FrameLabelConfig = .default,
        header: HeaderConfig = .default,
        watermark: WatermarkConfig? = nil,
        colorDNA: ColorDNAConfig = .default
    ) {
        self.frameLabel = frameLabel
        self.header = header
        self.watermark = watermark
        self.colorDNA = colorDNA
    }

    /// Preserves all original hardcoded defaults.
    public static let `default` = OverlayConfiguration()
}
