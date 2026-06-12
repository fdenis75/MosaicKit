import Foundation
import CoreGraphics
import SJSAssetExportSession

/// A shared, mode-agnostic description of the encoding settings that will be applied to a
/// preview export, regardless of which ``PreviewExportMode`` produced it.
///
/// Each export mode builds its settings differently — `.native` selects an
/// `AVAssetExportSession` preset, `.sjs` configures `VideoOutputSettings` directly, and
/// `.ffmpeg` assembles command-line flags via ``FFmpegEncodingOptions``. This struct normalises
/// the result of all three into one shape so UI code can present "what will this export
/// actually produce?" without branching on `exportMode`.
///
/// Use ``PreviewConfiguration/exportDescription`` to obtain this for a given configuration.
public struct PreviewExportDescription: Sendable, Hashable {

    /// The export mode this description was derived from.
    public let exportMode: PreviewExportMode

    /// Human-readable name of the preset / configuration in use
    /// (e.g. `"HEVC High"`, `"H.264 (libx264)"`, `"Passthrough"`).
    public let presetName: String

    /// Video codec, when known. `nil` for passthrough or other codecs not represented
    /// by ``Codec`` — see `presetName` for the actual codec in that case.
    public let videoCodec: Codec?

    /// Encoder profile (e.g. `"Main"`, `"High"`, `"Baseline"`), or `nil` when not applicable
    /// (e.g. HEVC, which has no selectable AVFoundation profile here).
    public let videoProfile: String?

    /// Encoder level (e.g. `"3.1"`, `"4.0"`, `"Auto"`), or `nil` when not applicable.
    public let videoLevel: String?

    /// Maximum output resolution enforced for this export, or `nil` if the source
    /// resolution is preserved (no resize beyond what the source already has).
    public let maxResolution: CGSize?

    /// Human-readable summary of the resolution behaviour.
    public let resolutionDescription: String

    /// Audio codec display name, or `nil` if audio is excluded from the export.
    public let audioCodec: String?

    /// Audio bitrate (e.g. `"128k"`), or `nil` if not applicable / encoder-determined.
    public let audioBitrate: String?

    /// Mode-specific additional detail not covered by the shared fields above
    /// (e.g. CRF/speed preset for FFmpeg, hardware vs. software encoder).
    public let additionalDetail: String?
}

// MARK: - Factories

extension PreviewExportDescription {

    /// Builds the description for ``PreviewExportMode/native``.
    static func native(config: PreviewConfiguration) -> PreviewExportDescription {
        let presetName = config.exportPresetName?.rawValue ?? config.effectiveExportPreset
        let preset = nativeExportPreset(rawValue: presetName)
        let profile = preset?.profile

        // The preset's own resolution is authoritative; only fall back to the configured
        // `exportMaxResolution` cap for "same as source" presets.
        var maxResolution = profile?.maxResolution
        var resolutionDescription = profile?.resolutionDescription ?? "Determined by preset \"\(presetName)\""
        if maxResolution == nil {
            if #available(macOS 26, iOS 26, *), let cap = config.exportMaxResolution {
                maxResolution = cap.cgSize
                resolutionDescription = "Capped to \(cap.rawValue) (\(Int(cap.maxWidth))x\(Int(cap.maxHeight)))"
            }
        }

        return PreviewExportDescription(
            exportMode: .native,
            presetName: preset?.displayString ?? presetName,
            videoCodec: profile?.codec,
            videoProfile: profile?.profile,
            videoLevel: profile?.level,
            maxResolution: maxResolution,
            resolutionDescription: resolutionDescription,
            audioCodec: config.includeAudio ? "AAC (preset default)" : nil,
            audioBitrate: nil,
            additionalDetail: nil
        )
    }

    /// Builds the description for ``PreviewExportMode/sjs``.
    static func sjs(config: PreviewConfiguration) -> PreviewExportDescription {
        let preset = config.sJSExportPresetName ?? .hevc
        let codec = preset.SJSCodec

        let videoCodec: Codec?
        let videoProfile: String?
        let videoLevel: String?
        switch codec {
        case .hevc:
            videoCodec = .hevc
            videoProfile = nil
            videoLevel = nil
        case .h264(let h264Profile):
            videoCodec = .h264
            (videoProfile, videoLevel) = h264Profile.profileAndLevel
        }

        var maxResolution: CGSize?
        var resolutionDescription = "Same as source"
        if #available(macOS 26, iOS 26, *), let cap = config.exportMaxResolution {
            maxResolution = cap.cgSize
            resolutionDescription = "Capped to \(cap.rawValue) (\(Int(cap.maxWidth))x\(Int(cap.maxHeight)))"
        }

        return PreviewExportDescription(
            exportMode: .sjs,
            presetName: preset.displayString,
            videoCodec: videoCodec,
            videoProfile: videoProfile,
            videoLevel: videoLevel,
            maxResolution: maxResolution,
            resolutionDescription: resolutionDescription,
            audioCodec: config.includeAudio ? "AAC" : nil,
            audioBitrate: nil,
            additionalDetail: preset.exportQuality == .NonApplicable ? nil : "Quality: \(preset.exportQuality.rawValue.capitalized)"
        )
    }

    /// Builds the description for ``PreviewExportMode/ffmpeg``.
    static func ffmpeg(config: PreviewConfiguration) -> PreviewExportDescription {
        let options = config.ffmpegEncodingOptions
            ?? FFmpegEncodingOptions.from(quality: config.compressionQuality, format: config.format)

        let videoCodec: Codec?
        switch options.videoCodec {
        case .hevc, .hevcVideoToolbox: videoCodec = .hevc
        case .h264, .h264VideoToolbox:  videoCodec = .h264
        case .copy:                       videoCodec = nil
        }

        let maxResolution = options.maxResolution?.cgSize
        let resolutionDescription: String
        if let cap = options.maxResolution {
            resolutionDescription = "Capped to \(cap.rawValue) (\(Int(cap.maxWidth))x\(Int(cap.maxHeight)))"
        } else {
            resolutionDescription = "Same as source"
        }

        var detailParts: [String] = []
        if options.videoCodec.isVideoToolbox {
            detailParts.append("Hardware (VideoToolbox)")
            if let bitrate = options.videoBitrate {
                detailParts.append("bitrate: \(bitrate)")
            } else {
                detailParts.append("q:v \(options.speedPreset.videoToolboxQuality)")
            }
            detailParts.append(options.speedPreset.videoToolboxRealtime ? "realtime" : "non-realtime")
        } else if options.videoCodec != .copy {
            if let crf = options.crf {
                detailParts.append("CRF \(crf)")
            } else if let bitrate = options.videoBitrate {
                detailParts.append("bitrate: \(bitrate)")
            }
            detailParts.append("preset: \(options.speedPreset.rawValue)")
        }

        return PreviewExportDescription(
            exportMode: .ffmpeg,
            presetName: options.videoCodec.displayName,
            videoCodec: videoCodec,
            videoProfile: nil,
            videoLevel: nil,
            maxResolution: maxResolution,
            resolutionDescription: resolutionDescription,
            audioCodec: config.includeAudio ? options.audioCodec.displayName : nil,
            audioBitrate: (config.includeAudio && options.audioCodec != .copy) ? options.audioBitrate : nil,
            additionalDetail: detailParts.isEmpty ? nil : detailParts.joined(separator: ", ")
        )
    }
}

// MARK: - VideoOutputSettings.H264Profile mapping

private extension VideoOutputSettings.H264Profile {
    /// Maps an SJS `H264Profile` to a `(profile, level)` pair matching the style used by
    /// ``NativeExportPresetProfile``.
    var profileAndLevel: (profile: String, level: String) {
        switch self {
        case .baselineAuto: return ("Baseline", "Auto")
        case .baseline30:   return ("Baseline", "3.0")
        case .baseline31:   return ("Baseline", "3.1")
        case .baseline41:   return ("Baseline", "4.1")
        case .mainAuto:     return ("Main", "Auto")
        case .main31:       return ("Main", "3.1")
        case .main32:       return ("Main", "3.2")
        case .main41:       return ("Main", "4.1")
        case .highAuto:     return ("High", "Auto")
        case .high40:       return ("High", "4.0")
        case .high41:       return ("High", "4.1")
        }
    }
}
