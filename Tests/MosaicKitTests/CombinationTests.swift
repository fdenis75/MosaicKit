import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

// MARK: - Result bookkeeping

private struct ComboResult: Sendable {
    let combo:     ComboConfig
    let elapsed:   TimeInterval
    let outputURL: URL?
    let errorDesc: String?
    var ok: Bool { errorDesc == nil }
}

// MARK: - Configuration descriptor

/// Fully specifies one parameter combination to generate.
private struct ComboConfig: Sendable {

    // ── identifiers ──────────────────────────────────────────────────────────
    let index: Int
    let group: String   // e.g. "G01-density"

    // ── layout ───────────────────────────────────────────────────────────────
    let density:     DensityConfig
    let layoutType:  LayoutType
    let aspectRatio: AspectRatio

    // ── metadata ─────────────────────────────────────────────────────────────
    let includeMetadata: Bool
    let headerHeight:    HeaderHeight     // used when includeMetadata = true

    // ── frame label ──────────────────────────────────────────────────────────
    let labelFormat:     FrameLabelFormat
    let labelPosition:   FrameLabelPosition
    let labelBackground: FrameLabelBackground

    // ── watermark ────────────────────────────────────────────────────────────
    let watermarkText: String?   // nil = no watermark

    // ── Color DNA ────────────────────────────────────────────────────────────
    let dnaStyle:    ColorDNAStyle?    // nil = off
    let dnaPosition: ColorDNAPosition

    // MARK: Short self-documenting filename

    var shortName: String {
        let g  = group.padding(toLength: 14, withPad: "_", startingAt: 0)
        let d  = density.name.lowercased()
        let l  = layoutCode(layoutType)
        let a  = aspectCode(aspectRatio)
        let m  = includeMetadata ? "M" : "N"
        let lf = fmtCode(labelFormat)
        let lb = bgCode(labelBackground)
        let lp = posCode(labelPosition)
        let wm = watermarkText != nil ? "wm" : "nowm"
        let dn = dnaCode()
        let hh = includeMetadata ? hhCode(headerHeight) : "na"
        return String(format: "%04d_%@_%@_%@_%@_%@_%@-%@@%@_%@_%@_%@",
                      index, g, d, l, a, m, lf, lb, lp, wm, dn, hh)
    }

    var filename: String { shortName + ".heic" }

    var fullDescription: String {
        [
            "group:           \(group)",
            "density:         \(density.name)  (factor=\(density.factor), extractsMultiplier=\(density.extractsMultiplier))",
            "layoutType:      \(layoutType.rawValue)",
            "aspectRatio:     \(aspectRatio.rawValue)",
            "includeMetadata: \(includeMetadata)",
            "headerHeight:    \(hhDesc(headerHeight))  (used only when metadata=true)",
            "labelFormat:     \(labelFormat.rawValue)",
            "labelPosition:   \(labelPosition.rawValue)",
            "labelBackground: \(labelBackground.rawValue)",
            "watermark:       \(watermarkText.map { "text(\"\($0)\")" } ?? "none")",
            "colorDNA:        \(dnaDesc())",
        ].joined(separator: "\n    ")
    }

    // MARK: Build MosaicConfiguration

    func toMosaicConfiguration(outputDir: URL, accentColor: MosaicColor) -> MosaicConfiguration {
        var config = MosaicConfiguration(
            width: 4000,
            density: density,
            format: .heif,
            layout: LayoutConfiguration(
                aspectRatio: aspectRatio,
                layoutType: layoutType
            ),
            includeMetadata: includeMetadata,
            useAccurateTimestamps: false,
            compressionQuality: 0.6,
            outputdirectory: outputDir
        )

        // Frame label — textColor always uses the fixed accent colour
        config.overlay.frameLabel = FrameLabelConfig(
            show:            labelFormat != .none,
            format:          labelFormat,
            position:        labelPosition,
            textColor:       accentColor,
            backgroundStyle: labelBackground
        )

        // Metadata header (six standard fields + colour palette)
        if includeMetadata {
            config.overlay.header = HeaderConfig(
                fields: [.title, .duration, .resolution, .codec, .bitrate, .colorPalette(swatchCount: 6)],
                height: headerHeight
            )
        }

        // Watermark — fixed accent colour, bottom-right corner
        if let text = watermarkText {
            config.overlay.watermark = WatermarkConfig(
                content:  .text(text),
                position: .bottomRight,
                opacity:  0.35,
                scale:    0.10
            )
        }

        // Color DNA
        if let style = dnaStyle {
            config.overlay.colorDNA = ColorDNAConfig(
                show:     true,
                height:   24,
                position: dnaPosition,
                style:    style
            )
        }

        return config
    }

    // MARK: Code helpers (private)

    private func layoutCode(_ l: LayoutType) -> String {
        switch l {
        case .auto:    return "auto"
        case .classic: return "cls"
        case .custom:  return "cst"
        case .dynamic: return "dyn"
        case .iphone:  return "iph"
        }
    }

    private func aspectCode(_ a: AspectRatio) -> String {
        switch a {
        case .widescreen: return "16x9"
        case .standard:   return "4x3"
        case .square:     return "1x1"
        case .ultrawide:  return "21x9"
        case .vertical:   return "9x16"
        }
    }

    private func fmtCode(_ f: FrameLabelFormat) -> String {
        switch f {
        case .timestamp:  return "ts"
        case .frameIndex: return "idx"
        case .none:       return "none"
        }
    }

    private func bgCode(_ b: FrameLabelBackground) -> String {
        switch b {
        case .pill:      return "pill"
        case .none:      return "bare"
        case .fullWidth: return "full"
        }
    }

    private func posCode(_ p: FrameLabelPosition) -> String {
        switch p {
        case .topLeft:     return "topL"
        case .topRight:    return "topR"
        case .bottomLeft:  return "botL"
        case .bottomRight: return "botR"
        case .center:      return "ctr"
        }
    }

    private func dnaCode() -> String {
        guard let style = dnaStyle else { return "nodna" }
        let s = style == .barcode ? "bc" : "gr"
        let p = dnaPosition == .bottom ? "bot" : "top"
        return "\(s)-\(p)"
    }

    private func hhCode(_ h: HeaderHeight) -> String {
        switch h {
        case .auto:         return "hauto"
        case .fixed(let v): return "h\(v)"
        }
    }

    private func hhDesc(_ h: HeaderHeight) -> String {
        switch h {
        case .auto:         return "auto"
        case .fixed(let v): return "fixed(\(v))"
        }
    }

    private func dnaDesc() -> String {
        guard let style = dnaStyle else { return "off" }
        return "show=true  style=\(style.rawValue)  position=\(dnaPosition.rawValue)  height=24px"
    }
}

// MARK: - All-combinations builder

private extension ComboConfig {

    // Baseline values — held constant in single-parameter sweeps
    static let baseDensity:   DensityConfig       = .m
    static let baseLayout:    LayoutType           = .custom
    static let baseAspect:    AspectRatio          = .widescreen
    static let baseMeta:      Bool                 = true
    static let baseHeaderH:   HeaderHeight         = .auto
    static let baseLabelFmt:  FrameLabelFormat     = .timestamp
    static let baseLabelPos:  FrameLabelPosition   = .bottomRight
    static let baseLabelBg:   FrameLabelBackground = .pill
    static let baseWatermark: String?              = nil
    static let baseDNA:       ColorDNAStyle?       = nil
    static let baseDNAPos:    ColorDNAPosition     = .bottom

    /// Generates all 200 combination descriptors.
    static func makeAll() -> [ComboConfig] {
        var configs: [ComboConfig] = []
        var idx = 1

        func add(
            group:    String,
            density:  DensityConfig       = baseDensity,
            layout:   LayoutType          = baseLayout,
            aspect:   AspectRatio         = baseAspect,
            meta:     Bool                = baseMeta,
            headerH:  HeaderHeight        = baseHeaderH,
            labelFmt: FrameLabelFormat    = baseLabelFmt,
            labelPos: FrameLabelPosition  = baseLabelPos,
            labelBg:  FrameLabelBackground = baseLabelBg,
            wm:       String?             = baseWatermark,
            dnaStyle: ColorDNAStyle?      = baseDNA,
            dnaPos:   ColorDNAPosition    = baseDNAPos
        ) {
            configs.append(ComboConfig(
                index: idx, group: group,
                density: density, layoutType: layout, aspectRatio: aspect,
                includeMetadata: meta, headerHeight: headerH,
                labelFormat: labelFmt, labelPosition: labelPos, labelBackground: labelBg,
                watermarkText: wm, dnaStyle: dnaStyle, dnaPosition: dnaPos
            ))
            idx += 1
        }

        // G01 – density sweep (7)
        for d in [DensityConfig.m] {
            add(group: "G01-density", density: d)
        }

        // G02 – layout type sweep (5)
        for l in [LayoutType.auto, .classic, .custom, .dynamic] {
            add(group: "G02-layout", layout: l)
        }

        // G03 – aspect ratio sweep (5)
        for a in [AspectRatio.widescreen, .standard, .square, .ultrawide, .vertical] {
            add(group: "G03-aspect", aspect: a)
        }

        // G04 – includeMetadata sweep (2)
        for m in [false, true] {
            add(group: "G04-metadata", meta: m)
        }

        // G05 – frame label format sweep (3)
        for f in [FrameLabelFormat.timestamp, .frameIndex, .none] {
            add(group: "G05-labelFmt", labelFmt: f)
        }

        // G06 – frame label position sweep (5)
        for p in [FrameLabelPosition.topLeft, .topRight, .bottomLeft, .bottomRight, .center] {
            add(group: "G06-labelPos", labelPos: p)
        }

        // G07 – frame label background sweep (3)
        for b in [FrameLabelBackground.pill, .none, .fullWidth] {
            add(group: "G07-labelBg", labelBg: b)
        }

        // G08 – watermark sweep (2)
        add(group: "G08-watermark", wm: nil)
        add(group: "G08-watermark", wm: "© Test Studio")

        // G09 – Color DNA sweep: off + 2 styles × 2 positions = 5
        add(group: "G09-colorDNA")   // off
        for style in [ColorDNAStyle.barcode, .gradient] {
            for pos in [ColorDNAPosition.bottom, .top] {
                add(group: "G09-colorDNA", dnaStyle: style, dnaPos: pos)
            }
        }

        // G10 – header height sweep (3, meta=true)
        for hh in [HeaderHeight.auto, .fixed(60), .fixed(120)] {
            add(group: "G10-headerH", meta: true, headerH: hh)
        }

        // G11 – density × layout cross-product (7 × 5 = 35)
        for d in [DensityConfig.m] {
            for l in [LayoutType.auto, .classic, .custom, .dynamic, .iphone] {
                add(group: "G11-dens×lay", density: d, layout: l)
            }
        }

        // G12 – density × aspect ratio cross-product (7 × 5 = 35)
        for d in [DensityConfig.m] {
            for a in [AspectRatio.widescreen, .standard, .square, .ultrawide, .vertical] {
                add(group: "G12-dens×asp", density: d, aspect: a)
            }
        }

        // G13 – overlay matrix: labelFmt(3) × labelBg(3) × watermark(2) × colorDNA(5) = 90
        let dnaStates: [(ColorDNAStyle?, ColorDNAPosition)] = [
            (nil,       .bottom),
            (.barcode,  .bottom),
            (.barcode,  .top),
            (.gradient, .bottom),
            (.gradient, .top),
        ]
        for lf in [FrameLabelFormat.timestamp, .frameIndex, .none] {
            for lb in [FrameLabelBackground.pill, .none, .fullWidth] {
                for wm in [String?.none, "© Test"] {
                    for (dnaS, dnaP) in dnaStates {
                        add(group: "G13-overlay",
                            labelFmt: lf, labelBg: lb,
                            wm: wm, dnaStyle: dnaS, dnaPos: dnaP)
                    }
                }
            }
        }

        return configs
    }
}

// MARK: - Timing impact analysis

private func timingSummary(_ results: [ComboResult]) -> String {
    let ok = results.filter(\.ok)
    guard !ok.isEmpty else { return "No successful generations — nothing to analyse.\n" }

    let bar72 = String(repeating: "═", count: 72)
    let bar52 = String(repeating: "─", count: 52)
    var out = ""

    // ── Per-parameter analysis ────────────────────────────────────────────────

    struct ParamStat {
        let name:   String
        let impact: TimeInterval   // max_mean − min_mean
        let rows:   [(label: String, mean: TimeInterval, n: Int)]
    }

    func analyse<T: Hashable>(
        name: String,
        key:   (ComboConfig) -> T,
        label: (T) -> String
    ) -> ParamStat {
        var buckets: [T: [TimeInterval]] = [:]
        for r in ok { buckets[key(r.combo), default: []].append(r.elapsed) }
        let means   = buckets.mapValues { $0.reduce(0,+) / Double($0.count) }
        let minMean = means.values.min() ?? 0
        let maxMean = means.values.max() ?? 0
        let rows    = buckets.map { k, times in
            (label: label(k),
             mean:  times.reduce(0,+) / Double(times.count),
             n:     times.count)
        }.sorted { $0.mean < $1.mean }
        return ParamStat(name: name, impact: maxMean - minMean, rows: rows)
    }

    let stats: [ParamStat] = [
        analyse(name: "density",           key: { $0.density.name },          label: { ".\($0.lowercased())" }),
        analyse(name: "layoutType",        key: { $0.layoutType },            label: { ".\($0.rawValue)" }),
        analyse(name: "aspectRatio",       key: { $0.aspectRatio },           label: { ".\($0.rawValue)" }),
        analyse(name: "includeMetadata",   key: { $0.includeMetadata },       label: { "\($0)" }),
        analyse(name: "frameLabelFormat",  key: { $0.labelFormat },           label: { ".\($0.rawValue)" }),
        analyse(name: "frameLabelPosition",key: { $0.labelPosition },         label: { ".\($0.rawValue)" }),
        analyse(name: "frameLabelBg",      key: { $0.labelBackground },       label: { ".\($0.rawValue)" }),
        analyse(name: "watermark",         key: { $0.watermarkText != nil },  label: { $0 ? "text" : "none" }),
        analyse(name: "colorDNA style",    key: { $0.dnaStyle?.rawValue ?? "off" }, label: { $0 }),
        analyse(name: "colorDNA position", key: { $0.dnaPosition.rawValue }, label: { ".\($0)" }),
        analyse(name: "headerHeight",      key: {
            switch $0.headerHeight {
            case .auto:         return "auto"
            case .fixed(let v): return "fixed(\(v))"
            }
        }, label: { $0 }),
    ]

    let ranked = stats.sorted { $0.impact > $1.impact }

    // ── Header ────────────────────────────────────────────────────────────────
    out += "MosaicKit Combination Test — Timing Impact Report\n"
    out += bar72 + "\n\n"
    out += String(format: "Configurations : %d total, %d succeeded, %d failed\n",
                  results.count, ok.count, results.count - ok.count)
    out += String(format: "Total wall time: %.0f s\n\n",
                  ok.map(\.elapsed).reduce(0, +))

    // ── Ranked impact ─────────────────────────────────────────────────────────
    out += "PARAMETER IMPACT RANKING  (impact = max_mean − min_mean)\n"
    out += bar52 + "\n"
    for (i, stat) in ranked.enumerated() {
        out += String(format: "  %2d. %-24s impact = %6.1f s\n",
                      i + 1, stat.name, stat.impact)
    }
    out += "\n"

    // ── Detailed breakdown ────────────────────────────────────────────────────
    out += "DETAILED BREAKDOWN BY PARAMETER\n"
    out += bar72 + "\n\n"
    for stat in ranked {
        out += String(format: "● %-24s (impact = %.1f s)\n", stat.name, stat.impact)
        for row in stat.rows {
            out += String(format: "  %-24s → %6.1f s  (n=%d)\n",
                          row.label, row.mean, row.n)
        }
        out += "\n"
    }

    // ── Per-group summary ─────────────────────────────────────────────────────
    out += "PER-GROUP SUMMARY\n"
    out += bar72 + "\n\n"
    var gBuckets: [String: [TimeInterval]] = [:]
    for r in ok { gBuckets[r.combo.group, default: []].append(r.elapsed) }
    for g in gBuckets.keys.sorted() {
        let ts  = gBuckets[g]!
        let avg = ts.reduce(0,+) / Double(ts.count)
        out += String(format: "  %-18s  n=%3d  mean=%6.1fs  min=%5.1fs  max=%6.1fs\n",
                      g, ts.count, avg, ts.min()!, ts.max()!)
    }

    // ── Extremes ──────────────────────────────────────────────────────────────
    func topN(_ sorted: [ComboResult], prefix: String) -> String {
        var s = prefix + "\n" + bar72 + "\n\n"
        for r in sorted.prefix(10) {
            s += String(format: "  %6.1fs  %@\n", r.elapsed, r.combo.shortName)
        }
        return s
    }
    out += "\n" + topN(ok.sorted { $0.elapsed > $1.elapsed }, prefix: "TOP-10 SLOWEST CONFIGURATIONS")
    out += "\n" + topN(ok.sorted { $0.elapsed < $1.elapsed }, prefix: "TOP-10 FASTEST CONFIGURATIONS")

    if results.count != ok.count {
        out += "\nFAILED CONFIGURATIONS\n"
        out += bar72 + "\n\n"
        for r in results.filter({ !$0.ok }) {
            out += "  \(r.combo.shortName)\n"
            out += "  → \(r.errorDesc ?? "unknown error")\n\n"
        }
    }

    return out
}

// MARK: - Test Suite

/// Generates a mosaic for every combination of mosaic-configuration parameters
/// and produces a timing-impact report in `TARGET_Folder`.
///
/// ## Totals
/// | Group | Description                        | Count |
/// |-------|------------------------------------|-------|
/// | G01   | density sweep                      |     7 |
/// | G02   | layout type sweep                  |     5 |
/// | G03   | aspect ratio sweep                 |     5 |
/// | G04   | includeMetadata sweep              |     2 |
/// | G05   | frame-label format sweep           |     3 |
/// | G06   | frame-label position sweep         |     5 |
/// | G07   | frame-label background sweep       |     3 |
/// | G08   | watermark sweep                    |     2 |
/// | G09   | Color DNA sweep                    |     5 |
/// | G10   | header height sweep                |     3 |
/// | G11   | density × layout cross-product     |    35 |
/// | G12   | density × aspect cross-product     |    35 |
/// | G13   | full overlay matrix (fmt×bg×wm×DNA)|    90 |
/// | **—** | **Total**                          | **200** |
///
/// ## Fixed settings for every combination
/// - width: **4000 px**
/// - format: **HEIF**
/// - compressionQuality: 0.6
/// - useAccurateTimestamps: false
/// - textColor / watermarkText use a fixed accent colour `rgba(0.2, 0.4, 0.8, 1.0)`
///
/// ## Run
/// ```bash
/// MOSAIC_TEST_VIDEO=/path/to/video.mp4 swift test --filter CombinationTests
/// # Override output directory:
/// MOSAIC_TARGET_FOLDER=/my/folder swift test --filter CombinationTests
/// ```
///
/// The test is **silently skipped** (passes trivially) when `MOSAIC_TEST_VIDEO` is
/// not set so it does not block normal CI runs.
@Suite("Combination Tests", .serialized)
struct CombinationTests {

    // MARK: Environment

    private static let videoPath: String? =
        ProcessInfo.processInfo.environment["MOSAIC_TEST_VIDEO"]

    private static var targetFolder: URL {
        let base = ProcessInfo.processInfo.environment["MOSAIC_TARGET_FOLDER"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                   .appendingPathComponent("Desktop/MosaicCombinations").path
        return URL(fileURLWithPath: base).appendingPathComponent("TARGET_Folder")
    }

    /// Fixed accent colour — used for `frameLabel.textColor` (the only colour
    /// parameter in the sweep); a mid-blue that reads clearly on most backgrounds.
    private let accentColor = MosaicColor(red: 0.2, green: 0.4, blue: 0.8)

    // MARK: Main test

    @Test("Generate all 200 parameter combinations and produce timing report")
    func runAllCombinations() async throws {

        // ── Guard: skip when no video is provided ─────────────────────────────
        guard let videoPath = Self.videoPath else {
            print("""

            ⚠️  CombinationTests skipped — MOSAIC_TEST_VIDEO is not set.
                Run with:
                  MOSAIC_TEST_VIDEO=/path/to/video.mp4 \\
                  swift test --filter CombinationTests

            """)
            return
        }

        // ── Setup ─────────────────────────────────────────────────────────────
        let videoURL     = URL(fileURLWithPath: videoPath)
        let targetFolder = Self.targetFolder

        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        let video     = try await VideoInput(from: videoURL)
        let generator = try MetalMosaicGenerator()

        let allConfigs = ComboConfig.makeAll()
        let total      = allConfigs.count

        print("""

        🎬 MosaicKit Combination Test
        ─────────────────────────────────────────────────────────────────────────
        Video      : \(video.title)  (\(String(format: "%.0f", video.duration ?? 0))s)
        Resolution : \(Int(video.width ?? 0))×\(Int(video.height ?? 0))
        Configs    : \(total)
        Output     : \(targetFolder.path)
        ─────────────────────────────────────────────────────────────────────────

        """)

        // ── Manifest header ───────────────────────────────────────────────────
        var manifest = """
        MosaicKit Combination Test — Configuration Manifest
        ════════════════════════════════════════════════════════════════════════
        Video   : \(videoURL.path)
        Date    : \(Date())
        Total   : \(total) configurations
        Fixed   : width=4000px  format=heif  compressionQuality=0.6
                  accentColor=rgba(0.2, 0.4, 0.8, 1.0)
        ════════════════════════════════════════════════════════════════════════

        """

        var results: [ComboResult] = []
        var succeeded = 0
        var failedCount = 0

        // ── Generation loop ───────────────────────────────────────────────────
        for (i, combo) in allConfigs.enumerated() {

            print(String(format: "[%4d/%4d]  %@  …", i + 1, total, combo.shortName),
                  terminator: " ")
            fflush(stdout)

            // Isolated per-config temp directory prevents filename collisions
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MosaicCombo-\(combo.index)-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            let mosaicConfig = combo.toMosaicConfiguration(outputDir: tmpDir,
                                                            accentColor: accentColor)
            let start       = Date()
            var outputURL: URL?
            var errorDesc:  String?

            do {
                let rawURL = try await generator.generate(for: video, config: mosaicConfig)

                // Rename and move into TARGET_Folder
                let dst = targetFolder.appendingPathComponent(combo.filename)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: rawURL, to: dst)
                outputURL = dst
                succeeded += 1

            } catch {
                errorDesc = error.localizedDescription
                failedCount += 1
            }

            // Clean up temp dir (best-effort)
            try? FileManager.default.removeItem(at: tmpDir)

            let elapsed = Date().timeIntervalSince(start)
            print(errorDesc == nil
                  ? String(format: "✅  %.1fs", elapsed)
                  : "❌  \(errorDesc!)")

            results.append(ComboResult(
                combo: combo,
                elapsed: elapsed,
                outputURL: outputURL,
                errorDesc: errorDesc
            ))

            // Append to manifest
            manifest += String(format: "[%04d]  %@\n", combo.index, combo.filename)
            manifest += "    \(combo.fullDescription.replacingOccurrences(of: "\n", with: "\n    "))\n"
            manifest += String(format: "    time   : %.2fs\n", elapsed)
            manifest += "    status : \(errorDesc == nil ? "OK" : "FAILED — \(errorDesc!)")\n\n"
        }

        print("\n── Generation complete: \(succeeded) succeeded, \(failedCount) failed ──\n")

        // ── Write manifest ────────────────────────────────────────────────────
        let manifestURL = targetFolder.appendingPathComponent("manifest.txt")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        print("📄 Manifest    : \(manifestURL.lastPathComponent)")

        // ── Write timing summary ──────────────────────────────────────────────
        let summary    = timingSummary(results)
        let summaryURL = targetFolder.appendingPathComponent("timing_summary.txt")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        print("📊 Timing      : \(summaryURL.lastPathComponent)\n")
        print(summary)

        // ── Assertion ─────────────────────────────────────────────────────────
        #expect(succeeded > 0, "Expected at least one successful mosaic generation")
    }
}
