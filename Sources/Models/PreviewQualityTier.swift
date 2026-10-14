import Foundation
import SJSAssetExportSession

/// Maps a preview `compressionQuality` (0...1) to an SJS codec tier.
///
/// The SJS exporter uses it when no `sJSExportPresetName` is set, and
/// ``PreviewExportDescription`` uses it to report what that export will produce, so the two
/// can't disagree (I-6). Tiers are ranges, not exact values: the former exact matching sent
/// every quality that wasn't 1.0, 0.75, 0.5 or 0.25 to the lowest tier.
internal enum PreviewQualityTier: Equatable, Sendable {
    case hevc
    case h264High
    case h264Main
    case h264Baseline

    internal init(quality: Double) {
        switch quality {
        case 0.875...: self = .hevc
        case 0.625...: self = .h264High
        case 0.375...: self = .h264Main
        default:       self = .h264Baseline
        }
    }

    internal var sjsCodec: VideoOutputSettings.Codec {
        switch self {
        case .hevc:         return .hevc
        case .h264High:     return .h264(.highAuto)
        case .h264Main:     return .h264(.mainAuto)
        case .h264Baseline: return .h264(.baselineAuto)
        }
    }
}
