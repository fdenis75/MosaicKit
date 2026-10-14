import Foundation
import CoreMedia

/// Detects video streams the current platform cannot decode, so inspection can fail fast with a
/// clear error instead of every frame extraction failing later (I-22).
///
/// Only H.264 profiles are checked: iOS decodes 8-bit 4:2:0 H.264 (Baseline, Main, High) but not
/// High 10 or the 4:2:2 and 4:4:4 profiles. macOS decodes them, so the check is enforced only
/// where it applies (`isEnforced`), while `unsupportedH264Description(avcC:)` stays testable on
/// every platform.
enum VideoCodecSupport {

    /// `true` on platforms that cannot decode the profiles `unsupportedH264Description` reports.
    static var isEnforced: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Names the H.264 profile of an `avcC` record when it is one iOS cannot decode, else `nil`.
    ///
    /// `avcC` layout (ISO/IEC 14496-15): byte 0 is the configuration version (1), byte 1 is
    /// `AVCProfileIndication` (the SPS `profile_idc`).
    static func unsupportedH264Description(avcC: Data) -> String? {
        guard avcC.count >= 4, avcC[avcC.startIndex] == 1 else { return nil }
        switch avcC[avcC.startIndex + 1] {
        case 110: return "H.264 High 10"
        case 122: return "H.264 High 4:2:2"
        case 244: return "H.264 High 4:4:4 Predictive"
        case 44:  return "H.264 High 4:4:4 Intra (CAVLC)"
        default:  return nil
        }
    }

    /// The `avcC` record of an H.264 format description, if it has one.
    static func avcC(of formatDescription: CMFormatDescription) -> Data? {
        let key = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        let atoms = CMFormatDescriptionGetExtension(formatDescription, extensionKey: key) as? [String: Any]
        return atoms?["avcC"] as? Data
    }

    /// The name of the unsupported codec/profile of `formatDescription` on this platform, or
    /// `nil` when the stream is decodable (or the platform decodes everything we check).
    static func unsupportedCodecName(of formatDescription: CMFormatDescription) -> String? {
        guard isEnforced, let avcC = avcC(of: formatDescription) else { return nil }
        return unsupportedH264Description(avcC: avcC)
    }
}
