import Foundation
import AVFoundation
import OSLog
import SJSAssetExportSession

/// Selects which encoding engine to use when generating a preview video.
public enum PreviewExportMode: String, Codable, Sendable, Hashable {
    /// Apple's `AVAssetExportSession` with a preset-based quality selector.
    case native
    /// `SJSAssetExportSession` with fine-grained codec and bitrate control.
    case sjs
    /// Passthrough export to a temp file followed by FFmpeg transcoding.
    /// Requires `PreviewConfiguration.ffmpegBinaryPath` to be set.
    case ffmpeg
    
    
    public var displayString: String {
        switch self {
        case .native:
            return "Apple Native"
        case .sjs:
            return "Custom AvFoundation Export"
        case .ffmpeg:
            return "FFmpeg"
        }
    }
}

/// Configuration for video preview generation
// @available(macOS 26, iOS 26, *)
public struct PreviewConfiguration: Codable, Sendable, Hashable {

    private static let logger = Logger(subsystem: "com.mosaickit", category: "PreviewConfiguration")

    // MARK: - Properties

    /// Target duration for the preview video (in seconds)
    public var targetDuration: TimeInterval

    /// Minimum duration for each extract (in seconds).
    ///
    /// Set to `nil` to disable minimum extract duration adjustment.
    public var minimumExtractDuration: TimeInterval?

    /// Maximum playback speed multiplier.
    ///
    /// Set to `nil` to allow the calculated playback speed without an upper cap.
    public var maximumPlaybackSpeed: Double?

    /// Density level determining the number of extracts
    public var density: DensityConfig

    /// Output video format
    public var format: VideoFormat

    /// Whether to include audio in the preview
    public var includeAudio: Bool

    /// Output directory (if nil, uses video's parent directory)
    public var outputDirectory: URL?

    /// Whether to include full path in the output filename
    public var fullPathInName: Bool

    /// Compression quality (0.0 - 1.0, where 1.0 is highest quality).
    /// Used by the SJSAssetExportSession export path to determine codec and bitrate,
    /// and by the native export path for quality-based preset selection via ``VideoFormat/exportPreset(quality:)``.
    public var compressionQuality: Double

    /// Selects the encoding engine. Replaces the deprecated ``useNativeExport`` flag.
    ///
    /// - `.native` — `AVAssetExportSession` with preset-based quality control.
    /// - `.sjs` — `SJSAssetExportSession` with fine-grained codec / bitrate control.
    /// - `.ffmpeg` — passthrough export to a temp file, then FFmpeg transcode to the
    ///   final destination. Requires ``ffmpegBinaryPath`` and is macOS-only.
    public var exportMode: PreviewExportMode

    /// Absolute path to the `ffmpeg` binary.
    /// Required (and validated before composition starts) when ``exportMode`` is `.ffmpeg`.
    public var ffmpegBinaryPath: String?

    /// Directory used for the intermediate passthrough file during the FFmpeg pipeline.
    /// When `nil`, a unique subdirectory under `FileManager.default.temporaryDirectory` is
    /// created automatically and deleted after encoding completes.
    public var ffmpegTempFolder: URL?

    /// Encoding options forwarded to the FFmpeg process.
    /// When `nil`, options are derived from ``compressionQuality`` via
    /// ``FFmpegEncodingOptions/from(quality:format:)``.
    public var ffmpegEncodingOptions: FFmpegEncodingOptions?

    /// Deprecated. Use ``exportMode`` instead.
    ///
    /// Reading returns `true` when `exportMode == .native`.
    /// Writing maps `true → .native` and `false → .sjs`.
    @available(*, deprecated, renamed: "exportMode")
    public var useNativeExport: Bool {
        get { exportMode == .native }
        set { exportMode = newValue ? .native : .sjs }
    }

    /// The AVAssetExportSession preset to use when ``exportMode`` is `.native`.
    /// If nil, a preset is automatically selected based on ``compressionQuality`` via ``VideoFormat/exportPreset(quality:)``.
    /// Common presets: AVAssetExportPresetHighestQuality, AVAssetExportPresetHEVC1920x1080,
    /// AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality, etc.
    public var exportPresetName: nativeExportPreset?


    /// The SJSAssetExportSession preset to use when ``exportMode`` is `.sjs`.
    public var sJSExportPresetName: SjSExportPreset?

    /// Whether to overwrite existing output files. When `false` (default),
    /// generation short-circuits and returns the existing URL if the output
    /// file already exists at the resolved path.
    public var overwrite: Bool = false

    /// When `false`, all `AppLifecycleMonitor.shared.waitUntilForeground()` calls
    /// are skipped. Set to `false` for daemons, XPC services, or CLI tools where
    /// the application lifecycle never transitions — the foreground wait would
    /// otherwise block indefinitely. Default is `true`.
    public var enableAppLifecycleMonitor: Bool = true

    /// When `false`, stall errors are propagated immediately without retrying.
    /// When `true` (default), the coordinator retries up to 3 times, waiting for
    /// the app to foreground between attempts.
    public var enableExportRetry: Bool = true

    /// Optional token-based template controlling the output directory layout.
    ///
    /// When `nil` (default), the legacy `{root}` layout is used.
    /// When set, the template is resolved against the following tokens:
    /// `{root}`, `{duration}`, `{density}`, `{format}`, `{date}`. Empty tokens
    /// are skipped; unknown tokens are left as-is.
    public var outputDirectoryTemplate: String? = nil

    /// Optional token-based template controlling the output filename.
    ///
    /// When `nil` (default), the legacy filename layout is used. When set, the
    /// template is resolved against the following tokens: `{name}`, `{ext}`,
    /// `{duration}`, `{density}`, `{format}`, `{audio}`, `{date}`. The template
    /// must end with `{ext}` or a literal extension; if no extension is
    /// present, `.{ext}` is appended automatically.
    public var filenameTemplate: String? = nil

    /// Backing store for `exportMaxResolution`.
    ///
    /// Stored as a raw `String?` so `PreviewConfiguration` remains fully `Codable`
    /// on macOS 15+ even though `ExportMaxResolution` itself requires macOS 26+.
    /// Defaults to `"1080p"` (mirrors `ExportMaxResolution._1080p`).
    private var _exportMaxResolutionRaw: String? = "1080p"

    /// Internal accessor for the raw resolution value, used by the video-generation
    /// pipeline to pass the preference through without requiring an `#available` context.
    var exportMaxResolutionRaw: String? { _exportMaxResolutionRaw }

    /// Maximum output resolution for the export. Defaults to 1080p.
    ///
    /// Only effective on macOS 26+ / iOS 26+. The underlying downscaling relies on
    /// `AVVideoComposition.Configuration` and related AVFoundation types introduced
    /// in macOS 26 / iOS 26. On earlier OS versions the value is persisted and
    /// round-trips correctly through `Codable`, but the export uses full source resolution.
    ///
    /// Wrap all read/write access in `if #available(macOS 26, iOS 26, *)`.
    @available(macOS 26, iOS 26, *)
    public var exportMaxResolution: ExportMaxResolution? {
        get { _exportMaxResolutionRaw.flatMap(ExportMaxResolution.init(rawValue:)) }
        set { _exportMaxResolutionRaw = newValue?.rawValue }
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case targetDuration, minimumExtractDuration, maximumPlaybackSpeed
        case density, format, includeAudio, outputDirectory
        case fullPathInName, compressionQuality
        // exportMode supersedes useNativeExport; both keys are kept for backward compatibility
        case exportMode, useNativeExport
        case exportPresetName, sJSExportPresetName
        /// Encodes/decodes as `"exportMaxResolution"` for backward compatibility
        /// even though the backing stored property is `_exportMaxResolutionRaw`.
        case exportMaxResolution
        case overwrite, outputDirectoryTemplate, filenameTemplate
        case ffmpegBinaryPath, ffmpegTempFolder, ffmpegEncodingOptions
        case enableAppLifecycleMonitor, enableExportRetry
    }

    // MARK: - Initialization

    /// Creates a `PreviewConfiguration` for all supported OS versions (macOS 15+).
    ///
    /// To set a maximum export resolution on macOS 26+, assign `exportMaxResolution`
    /// after construction:
    /// ```swift
    /// var config = PreviewConfiguration()
    /// if #available(macOS 26, iOS 26, *) {
    ///     config.exportMaxResolution = ._1080p
    /// }
    /// ```
    public init(
        targetDuration: TimeInterval = 60,
        minimumExtractDuration: TimeInterval? = nil,
        maximumPlaybackSpeed: Double? = nil,
        density: DensityConfig = .m,
        format: VideoFormat = .mp4,
        includeAudio: Bool = true,
        outputDirectory: URL? = nil,
        fullPathInName: Bool = false,
        compressionQuality: Double = 0.8,
        exportMode: PreviewExportMode = .native,
        exportPresetName: nativeExportPreset? = .AVAssetExportPresetHEVC1920x1080,
        sjSExportPresetName: SjSExportPreset? = .hevc,
        ffmpegBinaryPath: String? = nil,
        ffmpegTempFolder: URL? = nil,
        ffmpegEncodingOptions: FFmpegEncodingOptions? = nil,
        enableAppLifecycleMonitor: Bool = true,
        enableExportRetry: Bool = true
    ) {
        self.targetDuration = targetDuration
        self.minimumExtractDuration = minimumExtractDuration
        self.maximumPlaybackSpeed = maximumPlaybackSpeed
        self.density = density
        self.format = format
        self.includeAudio = includeAudio
        self.outputDirectory = outputDirectory
        self.fullPathInName = fullPathInName
        self.compressionQuality = min(max(compressionQuality, 0.0), 1.0)
        self.exportMode = exportMode
        self.exportPresetName = exportPresetName
        self.sJSExportPresetName = sjSExportPresetName ?? .hevc
        self.ffmpegBinaryPath = ffmpegBinaryPath
        self.ffmpegTempFolder = ffmpegTempFolder
        self.ffmpegEncodingOptions = ffmpegEncodingOptions
        self.enableAppLifecycleMonitor = enableAppLifecycleMonitor
        self.enableExportRetry = enableExportRetry
        // _exportMaxResolutionRaw defaults to "1080p" via the property declaration
    }

    /// Deprecated. Use ``init(exportMode:)`` instead.
    @available(*, deprecated, renamed: "init(exportMode:)")
    public init(
        targetDuration: TimeInterval = 60,
        minimumExtractDuration: TimeInterval? = nil,
        maximumPlaybackSpeed: Double? = nil,
        density: DensityConfig = .m,
        format: VideoFormat = .mp4,
        includeAudio: Bool = true,
        outputDirectory: URL? = nil,
        fullPathInName: Bool = false,
        compressionQuality: Double = 0.8,
        useNativeExport: Bool,
        exportPresetName: nativeExportPreset? = .AVAssetExportPresetHEVC1920x1080,
        sjSExportPresetName: SjSExportPreset? = .hevc
    ) {
        self.targetDuration = targetDuration
        self.minimumExtractDuration = minimumExtractDuration
        self.maximumPlaybackSpeed = maximumPlaybackSpeed
        self.density = density
        self.format = format
        self.includeAudio = includeAudio
        self.outputDirectory = outputDirectory
        self.fullPathInName = fullPathInName
        self.compressionQuality = min(max(compressionQuality, 0.0), 1.0)
        self.exportMode = useNativeExport ? .native : .sjs
        self.exportPresetName = exportPresetName
        self.sJSExportPresetName = sjSExportPresetName ?? .hevc
        self.ffmpegBinaryPath = nil
        self.ffmpegTempFolder = nil
        self.ffmpegEncodingOptions = nil
        self.enableAppLifecycleMonitor = true
        self.enableExportRetry = true
    }

    /// Creates a `PreviewConfiguration` with an explicit maximum export resolution.
    ///
    /// Requires macOS 26+ / iOS 26+ because `ExportMaxResolution` relies on
    /// `AVVideoComposition.Configuration` (introduced in macOS 26 / iOS 26).
    @available(macOS 26, iOS 26, *)
    public init(
        targetDuration: TimeInterval = 60,
        minimumExtractDuration: TimeInterval? = nil,
        maximumPlaybackSpeed: Double? = nil,
        density: DensityConfig = .m,
        format: VideoFormat = .mp4,
        includeAudio: Bool = true,
        outputDirectory: URL? = nil,
        fullPathInName: Bool = false,
        compressionQuality: Double = 0.8,
        exportMode: PreviewExportMode = .native,
        exportPresetName: nativeExportPreset? = .AVAssetExportPresetHEVC1920x1080,
        sjSExportPresetName: SjSExportPreset? = .hevc,
        maxResolution: ExportMaxResolution? = ._1080p,
        ffmpegBinaryPath: String? = nil,
        ffmpegTempFolder: URL? = nil,
        ffmpegEncodingOptions: FFmpegEncodingOptions? = nil,
        enableAppLifecycleMonitor: Bool = true,
        enableExportRetry: Bool = true
    ) {
        self.targetDuration = targetDuration
        self.minimumExtractDuration = minimumExtractDuration
        self.maximumPlaybackSpeed = maximumPlaybackSpeed
        self.density = density
        self.format = format
        self.includeAudio = includeAudio
        self.outputDirectory = outputDirectory
        self.fullPathInName = fullPathInName
        self.compressionQuality = min(max(compressionQuality, 0.0), 1.0)
        self.exportMode = exportMode
        self.exportPresetName = exportPresetName
        self.sJSExportPresetName = sjSExportPresetName ?? .hevc
        self._exportMaxResolutionRaw = (maxResolution ?? ._1080p).rawValue
        self.ffmpegBinaryPath = ffmpegBinaryPath
        self.ffmpegTempFolder = ffmpegTempFolder
        self.ffmpegEncodingOptions = ffmpegEncodingOptions
        self.enableAppLifecycleMonitor = enableAppLifecycleMonitor
        self.enableExportRetry = enableExportRetry
    }

    
    
    /// The effective export preset: explicit ``exportPresetName`` if set, otherwise derived from quality.
    public var effectiveExportPreset: String {
        exportPresetName?.rawValue ?? format.exportPreset(quality: compressionQuality)
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetDuration = try container.decode(TimeInterval.self, forKey: .targetDuration)
        minimumExtractDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .minimumExtractDuration)
        maximumPlaybackSpeed = try container.decodeIfPresent(Double.self, forKey: .maximumPlaybackSpeed)
        density = try container.decode(DensityConfig.self, forKey: .density)
        format = try container.decode(VideoFormat.self, forKey: .format)
        includeAudio = try container.decode(Bool.self, forKey: .includeAudio)
        outputDirectory = try container.decodeIfPresent(URL.self, forKey: .outputDirectory)
        fullPathInName = try container.decode(Bool.self, forKey: .fullPathInName)
        compressionQuality = min(max(try container.decode(Double.self, forKey: .compressionQuality), 0.0), 1.0)
        // Backward compat: prefer `exportMode`; fall back to mapping the old `useNativeExport` bool
        if let mode = try container.decodeIfPresent(PreviewExportMode.self, forKey: .exportMode) {
            exportMode = mode
        } else {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .useNativeExport) ?? true
            exportMode = legacy ? .native : .sjs
        }
        exportPresetName = try container.decodeIfPresent(nativeExportPreset.self, forKey: .exportPresetName)
        sJSExportPresetName = try container.decodeIfPresent(SjSExportPreset.self, forKey: .sJSExportPresetName) ?? .hevc
        // Decoded as String? so this round-trips correctly on all OS versions.
        // ExportMaxResolution itself requires macOS 26+; storing as a raw value keeps
        // PreviewConfiguration Codable on macOS 15+.
        _exportMaxResolutionRaw = try container.decodeIfPresent(String.self, forKey: .exportMaxResolution) ?? "1080p"
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false
        outputDirectoryTemplate = try container.decodeIfPresent(String.self, forKey: .outputDirectoryTemplate)
        filenameTemplate = try container.decodeIfPresent(String.self, forKey: .filenameTemplate)
        ffmpegBinaryPath = try container.decodeIfPresent(String.self, forKey: .ffmpegBinaryPath)
        ffmpegTempFolder = try container.decodeIfPresent(URL.self, forKey: .ffmpegTempFolder)
        ffmpegEncodingOptions = try container.decodeIfPresent(FFmpegEncodingOptions.self, forKey: .ffmpegEncodingOptions)
        enableAppLifecycleMonitor = try container.decodeIfPresent(Bool.self, forKey: .enableAppLifecycleMonitor) ?? true
        enableExportRetry = try container.decodeIfPresent(Bool.self, forKey: .enableExportRetry) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetDuration, forKey: .targetDuration)
        try container.encode(minimumExtractDuration, forKey: .minimumExtractDuration)
        try container.encode(maximumPlaybackSpeed, forKey: .maximumPlaybackSpeed)
        try container.encode(density, forKey: .density)
        try container.encode(format, forKey: .format)
        try container.encode(includeAudio, forKey: .includeAudio)
        try container.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
        try container.encode(fullPathInName, forKey: .fullPathInName)
        try container.encode(compressionQuality, forKey: .compressionQuality)
        try container.encode(exportMode, forKey: .exportMode)
        try container.encodeIfPresent(exportPresetName, forKey: .exportPresetName)
        try container.encodeIfPresent(sJSExportPresetName, forKey: .sJSExportPresetName)
        try container.encodeIfPresent(_exportMaxResolutionRaw, forKey: .exportMaxResolution)
        try container.encode(overwrite, forKey: .overwrite)
        try container.encodeIfPresent(outputDirectoryTemplate, forKey: .outputDirectoryTemplate)
        try container.encodeIfPresent(filenameTemplate, forKey: .filenameTemplate)
        try container.encodeIfPresent(ffmpegBinaryPath, forKey: .ffmpegBinaryPath)
        try container.encodeIfPresent(ffmpegTempFolder, forKey: .ffmpegTempFolder)
        try container.encodeIfPresent(ffmpegEncodingOptions, forKey: .ffmpegEncodingOptions)
        try container.encode(enableAppLifecycleMonitor, forKey: .enableAppLifecycleMonitor)
        try container.encode(enableExportRetry, forKey: .enableExportRetry)
    }

    // MARK: - Extract Calculation

    /// Base number of video extracts based on density (before duration adjustment)
    public var baseExtractCount: Int {
        switch density.name {
        case "XXL": return 4
        case "XL": return 8
        case "L": return 12
        case "M": return 16
        case "S": return 24
        case "XS": return 32
        case "XXS": return 48
        default:
            // For custom densities, calculate based on factor (base 16)
            return max(1, Int(16.0 * density.factor))
        }
    }
    
    /// Base extract count for a given density name (static variant of ``baseExtractCount``).
    /// - Parameter density: Density name string (e.g. "XL", "M", "XXS")
    /// - Returns: Number of extracts for the given density
    public static func exterEtractCount(density: String) -> Int
    {switch density.uppercased() {
    case "XXL": return 4
    case "XL": return 8
    case "L": return 12
    case "M": return 16
    case "S": return 24
    case "XS": return 32
    case "XXS": return 48
    default:
        // For custom densities, calculate based on factor (base 16)
        return max(1,16)
    }
        
    }

    /// Calculate number of video extracts based on density and video duration
    /// - Parameter videoDuration: Duration of the input video in seconds
    /// - Returns: Total extract count (base count + duration-based adjustment)
    public func extractCount(forVideoDuration videoDuration: TimeInterval) -> Int {
        let durationAdjustment = ((videoDuration > 1800.00) ? 8.0 : 4.0) * log(videoDuration)
        let totalCount = Double(baseExtractCount) + durationAdjustment
        Self.logger.debug("extractCount(forVideoDuration:) -> \(totalCount)")
        return max(1, Int(totalCount.rounded()))
    }
    public static func extractCountExt(forVideoDuration videoDuration: TimeInterval, density: String, targetDuration: TimeInterval) -> Int {
        let durationAdjustment = ((videoDuration > 1800.00) ? 8.0 : 4.0) * log(videoDuration)
        let totalCount = Double(self.exterEtractCount(density: density)) + durationAdjustment
        Self.logger.debug("extractCount(forVideoDuration:) -> \(totalCount)")
        return max(1, Int(totalCount.rounded()))
    }
    

    /// Calculate the duration per extract and playback speed
    /// - Parameter videoDuration: Duration of the input video in seconds
    /// - Returns: Tuple of (extractDuration, playbackSpeed)
    public func calculateExtractParameters(forVideoDuration videoDuration: TimeInterval) -> (extractDuration: TimeInterval, playbackSpeed: Double) {
        let count = extractCount(forVideoDuration: videoDuration)
        let baseExtractDuration = targetDuration / Double(count)
        guard let minimumExtractDuration = normalizedMinimumExtractDuration else {
            return (baseExtractDuration, 1.0)
        }

        if baseExtractDuration >= minimumExtractDuration {
            // Each extract can meet the configured minimum duration at normal speed.
            return (baseExtractDuration, 1.0)
        } else {
            // Need to speed up playback to fit extracts
            let minimumTotalDuration = minimumExtractDuration * Double(count)
            let requiredSpeed = minimumTotalDuration / targetDuration
            let cappedSpeed = normalizedMaximumPlaybackSpeed.map { min(requiredSpeed, $0) } ?? requiredSpeed

            // Calculate actual extract duration based on capped speed
            let actualExtractDuration = targetDuration * cappedSpeed / Double(count)

            return (actualExtractDuration, cappedSpeed)
        }
    }

    // MARK: - Output Path Generation

    /// Generate output directory for preview video
    /// - Parameters:
    ///   - videoInput: The source video
    /// - Returns: URL for output directory
    public func generateOutputDirectory(for videoInput: VideoInput) -> URL {
        let baseDirectory = outputDirectory ?? videoInput.url.deletingLastPathComponent()

        if let template = outputDirectoryTemplate {
            return resolveDirectoryTemplate(template, rootURL: baseDirectory, videoInput: videoInput)
        }

        return baseDirectory
          //  .appendingPathComponent("movieprev", isDirectory: true)
    }

    /// Generate filename for the preview video
    /// - Parameters:
    ///   - videoInput: The source video
    /// - Returns: Filename string
    public func generateFilename(for videoInput: VideoInput) -> String {
        let originalFilename = videoInput.url.deletingPathExtension().lastPathComponent.replacingNonAlphanumerics(with: "_")

        if let template = filenameTemplate {
            return resolveFilenameTemplate(
                template,
                originalFilename: originalFilename,
                videoInput: videoInput
            )
        }

        let durationLabel = formatDuration(targetDuration)
        let audioLabel = includeAudio ? "audio" : "noaudio"
        let exportLabel: String
        let resolution = _exportMaxResolutionRaw ?? "auto"
        switch exportMode {
        case .native:
            let preset = (exportPresetName?.fileString ?? effectiveExportPreset)
            exportLabel = "\(preset)_nat"
        case .sjs:
            let codec = sJSExportPresetName?.displayString ?? "default"
            exportLabel = "\(codec)_sjs"
        case .ffmpeg:
            let codec = ffmpegEncodingOptions?.videoCodec.rawValue
                ?? FFmpegEncodingOptions.from(quality: compressionQuality, format: format).videoCodec.rawValue
            exportLabel = "\(codec)_ffmpeg"
        }
        let timingLabel = extractTimingFilenameComponent.map { "_\($0)" } ?? ""
        let configHash = "\(durationLabel)_\(density.name)_\(format.rawValue)_\(audioLabel)_\(exportLabel)_\(resolution)\(timingLabel)"

        if fullPathInName {
            // Use full path in filename
            let sanitizedPath = videoInput.url.deletingLastPathComponent().path.replacingNonAlphanumerics(with: "_")
            return "\(sanitizedPath)_\(originalFilename)_preview_\(configHash).\(format.fileExtension)"
        } else {
            return "_preview_\(originalFilename)_\(configHash).\(format.fileExtension)"
        }
    }

    // MARK: - Template Resolution

    /// Resolve `outputDirectoryTemplate` against the available token set.
    private func resolveDirectoryTemplate(
        _ template: String,
        rootURL: URL,
        videoInput: VideoInput
    ) -> URL {
        let today = Self.todayString()
        let values: [String: String?] = [
            "root": rootURL.path,
            "exportMode": exportMode.displayString,
            "duration": formatDuration(targetDuration),
            "density": density.name,
            "format": format.rawValue,
            "date": today
        ]

        let components = template.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var resolvedRoot: URL = rootURL
        var trailing: [String] = []
        var sawRoot = false

        for (idx, component) in components.enumerated() {
            let resolved = Self.applyTokens(to: component, values: values)

            if !sawRoot && component.contains("{root}") {
                resolvedRoot = rootURL
                let extra = resolved.replacingOccurrences(of: rootURL.path, with: "")
                let trimmed = extra.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !trimmed.isEmpty {
                    trailing.append(trimmed)
                }
                sawRoot = true
                continue
            }

            if resolved.isEmpty { continue }

            if idx == 0 && !sawRoot && resolved.hasPrefix("/") {
                resolvedRoot = URL(fileURLWithPath: resolved)
                sawRoot = true
                continue
            }

            trailing.append(resolved)
        }

        var result = resolvedRoot
        for part in trailing {
            result = result.appendingPathComponent(part)
        }
        return result
    }

    /// Resolve `filenameTemplate` against the available token set.
    private func resolveFilenameTemplate(
        _ template: String,
        originalFilename: String,
        videoInput: VideoInput
    ) -> String {
        let today = Self.todayString()
        let values: [String: String?] = [
            "name": Self.sanitizeForFilePath(originalFilename),
            "ext": format.fileExtension,
            "duration": formatDuration(targetDuration),
            "density": density.name,
            "format": format.rawValue,
            "exportMode": exportMode.displayString,
            "audio": includeAudio ? "audio" : "noaudio",
            "date": today
        ]

        var resolved = Self.applyTokens(to: template, values: values)

        let lastPathExt = (resolved as NSString).pathExtension
        if lastPathExt.isEmpty {
            resolved = "\(resolved).\(format.fileExtension)"
        }

        return resolved
    }

    /// Substitute `{token}` placeholders in `input` using the provided value
    /// map. Tokens whose value is `nil` resolve to an empty string. Unknown
    /// tokens are left untouched.
    fileprivate static func applyTokens(to input: String, values: [String: String?]) -> String {
        var output = input
        for (key, value) in values {
            let placeholder = "{\(key)}"
            guard output.contains(placeholder) else { continue }
            let replacement = value ?? ""
            output = output.replacingOccurrences(of: placeholder, with: replacement)
        }
        return output
    }
    
    /// Sanitize a string for use in file paths.
    fileprivate static func sanitizeForFilePath(_ string: String) -> String {
        return string.replacingNonAlphanumerics(with: "_")
    }

    /// Current date formatted as `yyyy-MM-dd`.
    fileprivate static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Format duration for filename (e.g., "30s", "1m", "2m30s")
    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes == 0 {
            return "\(seconds)s"
        } else if seconds == 0 {
            return "\(minutes)m"
        } else {
            return "\(minutes)m\(seconds)s"
        }
    }

    private var extractTimingFilenameComponent: String? {
        guard minimumExtractDuration != nil || maximumPlaybackSpeed != nil else {
            return nil
        }

        let minimumLabel = minimumExtractDuration.map { "min\(Self.filenameNumber($0))s" } ?? "minoff"
        let maximumLabel = maximumPlaybackSpeed.map { "max\(Self.filenameNumber($0))x" } ?? "maxoff"
        return "\(minimumLabel)_\(maximumLabel)"
    }

    private static func filenameNumber(_ value: Double) -> String {
        var formatted = String(format: "%.2f", value)
        while formatted.hasSuffix("0") {
            formatted.removeLast()
        }
        if formatted.hasSuffix(".") {
            formatted.removeLast()
        }
        return formatted
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: ".", with: "p")
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(targetDuration)
        hasher.combine(minimumExtractDuration)
        hasher.combine(maximumPlaybackSpeed)
        hasher.combine(density)
        hasher.combine(format)
        hasher.combine(includeAudio)
        hasher.combine(compressionQuality)
        hasher.combine(exportMode)
        hasher.combine(exportPresetName)
    }

    private var normalizedMinimumExtractDuration: TimeInterval? {
        guard let minimumExtractDuration,
              minimumExtractDuration.isFinite,
              minimumExtractDuration > 0 else {
            return nil
        }
        return minimumExtractDuration
    }

    private var normalizedMaximumPlaybackSpeed: Double? {
        guard let maximumPlaybackSpeed,
              maximumPlaybackSpeed.isFinite else {
            return nil
        }
        return max(1.0, maximumPlaybackSpeed)
    }
}

// MARK: - Predefined Durations

// @available(macOS 26, iOS 26, *)
extension PreviewConfiguration {
    /// Common preview durations (30 second increments from 30s to 5m)
    public static let standardDurations: [TimeInterval] = [
        30,    // 30 seconds
        60,    // 1 minute
        90,    // 1:30
        120,   // 2 minutes
        150,   // 2:30
        180,   // 3 minutes
        210,   // 3:30
        240,   // 4 minutes
        270,   // 4:30
        300    // 5 minutes
    ]

    /// Get display label for a duration
    public static func durationLabel(for duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes == 0 {
            return "\(seconds)s"
        } else if seconds == 0 {
            return "\(minutes)m"
        } else {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
    }
}
extension PreviewConfiguration: CustomDebugStringConvertible {
    public var debugDescription: String {
        let durationLabel = Self.durationLabel(for: targetDuration)
        let audioLabel = includeAudio ? "audio" : "no audio"
        let exportDetail: String
        switch exportMode {
        case .native:
            exportDetail = "native(preset: \(exportPresetName?.displayString ?? effectiveExportPreset))"
        case .sjs:
            let codec = sJSExportPresetName?.displayString ?? "default"
            let res = _exportMaxResolutionRaw ?? "auto"
            exportDetail = "SJS(codec: \(codec), maxRes: \(res))"
        case .ffmpeg:
            let codec = ffmpegEncodingOptions?.videoCodec.rawValue ?? "derived"
            let binary = ffmpegBinaryPath ?? "unset"
            exportDetail = "FFmpeg(codec: \(codec), binary: \(binary))"
        }
        return "PreviewConfiguration(duration: \(durationLabel), density: \(density.name), format: \(format.rawValue), \(audioLabel), export: \(exportDetail))"
    }
}

extension String {
    func replacingNonAlphanumerics(with replacement: String = "_") -> String {
        let allowed = CharacterSet.alphanumerics
        return self.unicodeScalars.map { allowed.contains($0) ? String($0) : replacement }.joined()
    }
}
