import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

struct OverlayConfigurationTests {

    // MARK: - FrameLabelConfig

    @Test("FrameLabelConfig default values reproduce original appearance")
    func frameLabelConfigDefaults() {
        let cfg = FrameLabelConfig.default
        #expect(cfg.show == true)
        #expect(cfg.format == .timestamp)
        #expect(cfg.position == .bottomRight)
        #expect(cfg.textColor.red == 1 && cfg.textColor.green == 1 && cfg.textColor.blue == 1)
        #expect(cfg.backgroundStyle == .pill)
    }

    @Test("FrameLabelConfig round-trips through Codable for all format/position/style combinations")
    func frameLabelConfigCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for format in [FrameLabelFormat.timestamp, .frameIndex, .none] {
            for position in [FrameLabelPosition.topLeft, .topRight, .bottomLeft, .bottomRight, .center] {
                for style in [FrameLabelBackground.pill, .none, .fullWidth] {
                    let original = FrameLabelConfig(
                        show: format != .none,
                        format: format,
                        position: position,
                        textColor: MosaicColor(red: 0.2, green: 0.4, blue: 0.8),
                        backgroundStyle: style
                    )
                    let data = try encoder.encode(original)
                    let decoded = try decoder.decode(FrameLabelConfig.self, from: data)

                    #expect(decoded.show == original.show)
                    #expect(decoded.format == original.format)
                    #expect(decoded.position == original.position)
                    #expect(decoded.backgroundStyle == original.backgroundStyle)
                    #expect(abs(decoded.textColor.red   - 0.2) < 0.001)
                    #expect(abs(decoded.textColor.green - 0.4) < 0.001)
                    #expect(abs(decoded.textColor.blue  - 0.8) < 0.001)
                }
            }
        }
    }

    // MARK: - HeaderHeight (manual Codable)

    @Test("HeaderHeight.auto round-trips through Codable")
    func headerHeightAutoCodable() throws {
        let data = try JSONEncoder().encode(HeaderHeight.auto)
        let decoded = try JSONDecoder().decode(HeaderHeight.self, from: data)
        #expect(decoded == .auto)
    }

    @Test("HeaderHeight.fixed round-trips with value preserved")
    func headerHeightFixedCodable() throws {
        for pixels in [40, 80, 120, 200] {
            let data = try JSONEncoder().encode(HeaderHeight.fixed(pixels))
            let decoded = try JSONDecoder().decode(HeaderHeight.self, from: data)
            #expect(decoded == .fixed(pixels), "fixed(\(pixels)) round-trip failed")
        }
    }

    @Test("HeaderHeight unknown type string decodes to .auto")
    func headerHeightUnknownTypeDecodesAuto() throws {
        // A JSON payload with an unrecognised type string should fall back to .auto
        let json = #"{"type":"unknown_future_case"}"#
        let decoded = try JSONDecoder().decode(HeaderHeight.self, from: Data(json.utf8))
        #expect(decoded == .auto)
    }

    // MARK: - MetadataField (manual Codable — highest-risk)

    @Test("MetadataField plain cases all round-trip correctly")
    func metadataFieldPlainCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let plainCases: [MetadataField] = [
            .title, .duration, .fileSize, .resolution,
            .codec, .bitrate, .frameRate, .filePath
        ]
        for field in plainCases {
            let data = try encoder.encode(field)
            let decoded = try decoder.decode(MetadataField.self, from: data)
            #expect(decoded == field, "Round-trip failed for .\(field)")
        }
    }

    @Test("MetadataField.colorPalette round-trips with swatchCount preserved")
    func metadataFieldColorPalette() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for count in [1, 5, 12, 20] {
            let original = MetadataField.colorPalette(swatchCount: count)
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(MetadataField.self, from: data)
            #expect(decoded == original, "colorPalette(swatchCount: \(count)) round-trip failed")
        }
    }

    @Test("MetadataField.custom round-trips with both label and value preserved")
    func metadataFieldCustom() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let pairs: [(String, String)] = [
            ("Director", "Jane Doe"),
            ("Studio", "Acme Films"),
            ("Note", "Contains special chars: \"<>&")
        ]
        for (label, value) in pairs {
            let original = MetadataField.custom(label: label, value: value)
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(MetadataField.self, from: data)
            #expect(decoded == original, "custom('\(label)', '\(value)') round-trip failed")
        }
    }

    @Test("MetadataField array containing all types round-trips correctly")
    func metadataFieldMixedArray() throws {
        let fields: [MetadataField] = [
            .title, .duration, .fileSize, .resolution, .codec,
            .bitrate, .frameRate, .filePath,
            .colorPalette(swatchCount: 7),
            .custom(label: "K", value: "V")
        ]
        let data = try JSONEncoder().encode(fields)
        let decoded = try JSONDecoder().decode([MetadataField].self, from: data)
        #expect(decoded == fields)
    }

    // MARK: - HeaderConfig

    @Test("HeaderConfig default contains six canonical fields")
    func headerConfigDefaults() {
        let cfg = HeaderConfig.default
        #expect(cfg.fields.count == 6)
        #expect(cfg.fields.contains(.title))
        #expect(cfg.fields.contains(.duration))
        #expect(cfg.fields.contains(.fileSize))
        #expect(cfg.fields.contains(.codec))
        #expect(cfg.fields.contains(.resolution))
        #expect(cfg.fields.contains(.bitrate))
        #expect(cfg.height == .auto)
        #expect(cfg.textColor == nil)
        #expect(cfg.backgroundColor == nil)
    }

    @Test("HeaderConfig round-trips through Codable with all field types and overrides")
    func headerConfigCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let original = HeaderConfig(
            fields: [.title, .duration, .colorPalette(swatchCount: 8), .custom(label: "K", value: "V")],
            height: .fixed(80),
            textColor: MosaicColor(red: 1, green: 1, blue: 1),
            backgroundColor: MosaicColor(red: 0.1, green: 0.1, blue: 0.1)
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(HeaderConfig.self, from: data)
        #expect(decoded.fields == original.fields)
        #expect(decoded.height == .fixed(80))
        #expect(abs((decoded.textColor?.red ?? 0) - 1) < 0.001)
        #expect(abs((decoded.backgroundColor?.blue ?? 0) - 0.1) < 0.001)
    }

    // MARK: - WatermarkContent (manual Codable)

    @Test("WatermarkContent.text round-trips preserving the string")
    func watermarkContentTextCodable() throws {
        let original = WatermarkContent.text("© Studio 2025")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatermarkContent.self, from: data)
        guard case .text(let t) = decoded else {
            #expect(Bool(false), "Expected .text case"); return
        }
        #expect(t == "© Studio 2025")
    }

    @Test("WatermarkContent.image round-trips preserving the URL")
    func watermarkContentImageCodable() throws {
        let url = URL(fileURLWithPath: "/tmp/logo.png")
        let original = WatermarkContent.image(url)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatermarkContent.self, from: data)
        guard case .image(let u) = decoded else {
            #expect(Bool(false), "Expected .image case"); return
        }
        #expect(u == url)
    }

    // MARK: - WatermarkConfig

    @Test("WatermarkConfig clamps opacity and scale to valid ranges")
    func watermarkConfigClamping() {
        let low  = WatermarkConfig(content: .text("x"), opacity: -1.0, scale: -0.5)
        #expect(low.opacity == 0.0)
        #expect(low.scale   == 0.01)

        let high = WatermarkConfig(content: .text("x"), opacity: 10.0, scale: 5.0)
        #expect(high.opacity == 1.0)
        #expect(high.scale   == 1.0)

        let ok = WatermarkConfig(content: .text("x"), opacity: 0.35, scale: 0.12)
        #expect(ok.opacity == 0.35)
        #expect(ok.scale   == 0.12)
    }

    @Test("WatermarkConfig round-trips for all five positions")
    func watermarkConfigCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for position in [WatermarkPosition.topLeft, .topRight, .bottomLeft, .bottomRight, .center] {
            let original = WatermarkConfig(content: .text("WM"), position: position, opacity: 0.5, scale: 0.15)
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(WatermarkConfig.self, from: data)
            #expect(decoded.position == original.position)
            #expect(abs(decoded.opacity - 0.5) < 0.001)
            #expect(abs(decoded.scale  - 0.15) < 0.001)
        }
    }

    // MARK: - ColorDNAConfig

    @Test("ColorDNAConfig clamps height to a minimum of 8 px")
    func colorDNAHeightClamp() {
        #expect(ColorDNAConfig(height: 0).height  == 8)
        #expect(ColorDNAConfig(height: 4).height  == 8)
        #expect(ColorDNAConfig(height: 8).height  == 8)
        #expect(ColorDNAConfig(height: 32).height == 32)
    }

    @Test("ColorDNAConfig default is hidden / 24 px / bottom / barcode")
    func colorDNADefaults() {
        let cfg = ColorDNAConfig.default
        #expect(cfg.show     == false)
        #expect(cfg.height   == 24)
        #expect(cfg.position == .bottom)
        #expect(cfg.style    == .barcode)
    }

    @Test("ColorDNAConfig round-trips for all style and position combinations")
    func colorDNACodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for style in [ColorDNAStyle.barcode, .gradient] {
            for position in [ColorDNAPosition.top, .bottom] {
                let original = ColorDNAConfig(show: true, height: 40, position: position, style: style)
                let data = try encoder.encode(original)
                let decoded = try decoder.decode(ColorDNAConfig.self, from: data)
                #expect(decoded.show     == true)
                #expect(decoded.height   == 40)
                #expect(decoded.position == original.position)
                #expect(decoded.style    == original.style)
            }
        }
    }

    // MARK: - OverlayConfiguration (umbrella)

    @Test("OverlayConfiguration.default reproduces all original hardcoded defaults")
    func overlayConfigurationDefault() {
        let overlay = OverlayConfiguration.default
        #expect(overlay.frameLabel.show           == true)
        #expect(overlay.frameLabel.format         == .timestamp)
        #expect(overlay.frameLabel.position       == .bottomRight)
        #expect(overlay.frameLabel.backgroundStyle == .pill)
        #expect(overlay.header.fields.count       == 6)
        #expect(overlay.header.height             == .auto)
        #expect(overlay.watermark                 == nil)
        #expect(overlay.colorDNA.show             == false)
    }

    @Test("OverlayConfiguration round-trips with nil watermark")
    func overlayConfigurationCodableNoWatermark() throws {
        let data = try JSONEncoder().encode(OverlayConfiguration.default)
        let decoded = try JSONDecoder().decode(OverlayConfiguration.self, from: data)
        #expect(decoded.watermark              == nil)
        #expect(decoded.frameLabel.format      == .timestamp)
        #expect(decoded.colorDNA.show          == false)
        #expect(decoded.header.fields.count    == 6)
    }

    @Test("OverlayConfiguration round-trips with all non-nil fields")
    func overlayConfigurationCodableWithWatermark() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let original = OverlayConfiguration(
            frameLabel: FrameLabelConfig(show: false, format: .frameIndex, position: .topLeft, backgroundStyle: .fullWidth),
            header: HeaderConfig(fields: [.filePath, .colorPalette(swatchCount: 4)], height: .fixed(60)),
            watermark: WatermarkConfig(content: .text("© Acme"), position: .topLeft, opacity: 0.4, scale: 0.1),
            colorDNA: ColorDNAConfig(show: true, height: 32, position: .top, style: .gradient)
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(OverlayConfiguration.self, from: data)

        #expect(decoded.frameLabel.show           == false)
        #expect(decoded.frameLabel.format         == .frameIndex)
        #expect(decoded.frameLabel.position       == .topLeft)
        #expect(decoded.frameLabel.backgroundStyle == .fullWidth)
        #expect(decoded.header.height             == .fixed(60))
        #expect(decoded.header.fields.count       == 2)
        #expect(decoded.watermark                 != nil)
        #expect(decoded.colorDNA.show             == true)
        #expect(decoded.colorDNA.style            == .gradient)
        #expect(decoded.colorDNA.position         == .top)
    }

    // MARK: - OverlayConfiguration embedded in MosaicConfiguration

    @Test("OverlayConfiguration survives a full MosaicConfiguration Codable round-trip")
    func overlayEmbeddedInMosaicConfigCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var config = MosaicConfiguration.default
        config.overlay = OverlayConfiguration(
            frameLabel: FrameLabelConfig(format: .frameIndex, position: .topLeft, backgroundStyle: .fullWidth),
            header: HeaderConfig(fields: [.title, .colorPalette(swatchCount: 5)], height: .fixed(100)),
            watermark: WatermarkConfig(content: .text("Test"), opacity: 0.5, scale: 0.2),
            colorDNA: ColorDNAConfig(show: true, height: 48, position: .top, style: .gradient)
        )
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(MosaicConfiguration.self, from: data)

        #expect(decoded.overlay.frameLabel.format         == .frameIndex)
        #expect(decoded.overlay.frameLabel.position       == .topLeft)
        #expect(decoded.overlay.frameLabel.backgroundStyle == .fullWidth)
        #expect(decoded.overlay.header.height             == .fixed(100))
        #expect(decoded.overlay.header.fields.count       == 2)
        #expect(decoded.overlay.watermark?.opacity        == 0.5)
        #expect(decoded.overlay.colorDNA.show             == true)
        #expect(decoded.overlay.colorDNA.style            == .gradient)
    }

    @Test("MosaicConfiguration.default overlay is preserved in Codable round-trip")
    func defaultOverlayInMosaicConfigCodable() throws {
        let data = try JSONEncoder().encode(MosaicConfiguration.default)
        let decoded = try JSONDecoder().decode(MosaicConfiguration.self, from: data)
        #expect(decoded.overlay.frameLabel.show  == true)
        #expect(decoded.overlay.watermark        == nil)
        #expect(decoded.overlay.colorDNA.show    == false)
    }
}
