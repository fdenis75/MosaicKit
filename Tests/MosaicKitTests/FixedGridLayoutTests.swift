import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import MosaicKit

/// The `fixedGrid` layout with `.adaptCanvas` (plan step G-2; spec
/// `codebase-analysis-docs/specs/SPEC_FIXED_GRID_LAYOUT.md`, section 7.1 and 7.2).
///
/// The geometry tests are pure: no media, no GPU. They sweep the grid sizes, source aspects,
/// widths and spacings the spec names and collect violations, so a failure prints the first few.
struct FixedGridLayoutTests {

    private let sizes = [1, 2, 3, 4, 5, 7, 10, 16, 30, 50]
    private let sourceAspects: [CGFloat] = [16.0 / 9, 4.0 / 3, 1, 21.0 / 9, 9.0 / 16]
    private let widths = [1000, 2000, 5120, 10_000]
    private let spacings: [CGFloat] = [4, 6, 12, 20]

    /// Plans one grid and returns the layout, or `nil` when it is infeasible.
    private func plan(
        _ rows: Int, _ columns: Int, aspect: CGFloat = 16.0 / 9, width: Int = 5120,
        spacing: CGFloat = 4, reserved: Int = 0, processor: LayoutProcessor = LayoutProcessor()
    ) -> FixedGridPlan {
        processor.planFixedGrid(
            GridSpecification(rows: rows, columns: columns), sourceAspectRatio: aspect,
            mosaicAspectRatio: .widescreen, mosaicWidth: width, spacing: spacing, reservedHeight: reserved
        )
    }

    /// Every feasible plan of the sweep, with its inputs.
    private func sweep() -> [(rows: Int, columns: Int, aspect: CGFloat, width: Int, spacing: CGFloat, layout: MosaicLayout, notes: [FixedGridNote])] {
        let processor = LayoutProcessor()
        var plans: [(Int, Int, CGFloat, Int, CGFloat, MosaicLayout, [FixedGridNote])] = []
        for rows in sizes where rows * 1 <= GridSpecification.maximumAxisCount {
            for columns in sizes where rows * columns <= GridSpecification.maximumCellCount {
                for aspect in sourceAspects {
                    for width in widths {
                        for spacing in spacings {
                            if case .layout(let layout, _, let notes) = plan(rows, columns, aspect: aspect, width: width, spacing: spacing, processor: processor) {
                                plans.append((rows, columns, aspect, width, spacing, layout, notes))
                            }
                        }
                    }
                }
            }
        }
        return plans
    }

    // MARK: - Feasible and infeasible

    @Test("1: count — a feasible grid has rows × columns cells, everywhere")
    func countProperty() {
        var violations: [String] = []
        let plans = sweep()
        for p in plans where p.layout.thumbCount != p.rows * p.columns
            || p.layout.positions.count != p.rows * p.columns
            || p.layout.thumbnailSizes.count != p.rows * p.columns
            || p.layout.rows != p.rows || p.layout.cols != p.columns {
            violations.append("\(p.rows)x\(p.columns) s=\(p.aspect) W=\(p.width)")
        }
        #expect(plans.count > 2000, "The sweep should keep a large feasible set (got \(plans.count))")
        #expect(violations.isEmpty, "\(violations.prefix(5))")
    }

    @Test("1b: the combinations that must be rejected are, with the intended issue and numbers")
    func infeasibleCombinations() {
        func issue(_ plan: FixedGridPlan) -> FixedGridIssue? {
            if case .infeasible(let issue, _) = plan { return issue }
            return nil
        }
        #expect(issue(plan(50, 50)) == .tooManyCells(cells: 2500, maximum: 1000))
        #expect(issue(plan(40, 40)) == .tooManyCells(cells: 1600, maximum: 1000))
        #expect(issue(plan(0, 4)) == .invalidCount(rows: 0, columns: 4))
        #expect(issue(plan(-1, 3)) == .invalidCount(rows: -1, columns: 3))
        #expect(issue(plan(3, 51)) == .invalidCount(rows: 3, columns: 51))
        // 50 columns at width 1000: 16 px wide frames, 9 px tall for 16:9 (the short side).
        #expect(issue(plan(1, 50, width: 1000)) == .cellsTooSmall(shortSide: 9, minimum: 40))
        // Spacing 20 is a 16 px inset: 44 px slots leave 28 x 16 px frames.
        #expect(issue(plan(1, 10, width: 476, spacing: 20)) == .cellsTooSmall(shortSide: 16, minimum: 40))
        // A very tall source: 50 rows of 1:10 frames cannot reach 40 px wide inside 16,384 px.
        #expect(issue(plan(50, 1, aspect: 0.1, width: 5120)) != nil)
        #expect(issue(plan(2, 2, aspect: .nan)) == .unknownSourceAspect)
        #expect(issue(plan(2, 2, aspect: 0)) == .unknownSourceAspect)
        // Fit modes that are not built yet say so instead of pretending.
        let letterbox = LayoutProcessor().planFixedGrid(
            GridSpecification(rows: 2, columns: 2, fit: .letterbox), sourceAspectRatio: 16.0 / 9,
            mosaicAspectRatio: .widescreen, mosaicWidth: 1920
        )
        #expect(issue(letterbox) == .fitModeUnavailable(.letterbox))
        // The 50 px sweeps the spec names stay on the right side of the rule.
        var wrong: [String] = []
        for rows in sizes {
            for columns in sizes {
                for width in widths where rows * columns <= 1000 {
                    let slot = (width - (columns - 1) * 4) / columns
                    if case .layout = plan(rows, columns, width: width), slot < 40 { wrong.append("\(rows)x\(columns) W=\(width)") }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(5))")
    }

    @Test("Every issue explains itself with its numbers")
    func issueExplanations() {
        #expect(FixedGridIssue.tooManyCells(cells: 2500, maximum: 1000).explanation.contains("at most 1000 cells"))
        #expect(FixedGridIssue.invalidCount(rows: 0, columns: 4).explanation.contains("0 × 4"))
        #expect(FixedGridIssue.cellsTooSmall(shortSide: 16, minimum: 40).explanation.contains("16 px"))
        #expect(FixedGridIssue.canvasTooTall(requiredHeight: 20_000, maximum: 16_000).explanation.contains("20000"))
        #expect(FixedGridIssue.unknownSourceAspect.explanation.contains("VideoInput(from:)"))
        #expect(FixedGridIssue.fitModeUnavailable(.crop).explanation.contains(".crop"))
        #expect(FixedGridIssue.aspectMismatch(cellAspect: 0.56, sourceAspect: 1.78, error: 2.16).explanation.contains("0.56:1"))
        #expect(FixedGridIssue.fillTooLow(fill: 0.3, minimum: 0.5).explanation.contains("30.0 %"))
    }

    // MARK: - Geometry

    @Test("2, 3, 4: no overlap, inside the canvas, exact 4 px gutters")
    func geometryProperties() {
        var violations: [String] = []
        let plans = sweep()
        for (index, p) in plans.enumerated() {
            let layout = p.layout
            let cw = Int(layout.thumbnailSize.width), ch = Int(layout.thumbnailSize.height)
            let canvasW = Int(layout.mosaicSize.width), canvasH = Int(layout.mosaicSize.height)
            let tag = "\(p.rows)x\(p.columns) s=\(p.aspect) W=\(p.width) sp=\(p.spacing)"
            if canvasW != p.columns * cw + (p.columns - 1) * 4 || canvasH != p.rows * ch + (p.rows - 1) * 4 { violations.append("canvas \(tag)") }
            for (i, position) in layout.positions.enumerated() {
                let size = layout.thumbnailSizes[i]
                if position.x < 0 || position.y < 0 || position.x + Int(size.width) > canvasW || position.y + Int(size.height) > canvasH {
                    violations.append("outside \(tag) cell \(i)")
                    break
                }
                if size != layout.thumbnailSize { violations.append("size \(tag)"); break }
                let column = i % p.columns, row = i / p.columns
                if position.x != column * (cw + 4) || position.y != row * (ch + 4) { violations.append("gutter \(tag) cell \(i)"); break }
            }
            // Pairwise overlap check on a sample of the small layouts.
            if index % 40 == 0, layout.positions.count <= 200 {
                for a in 0..<layout.positions.count {
                    for b in (a + 1)..<layout.positions.count {
                        let (pa, pb) = (layout.positions[a], layout.positions[b])
                        let separated = pa.x + cw <= pb.x || pb.x + cw <= pa.x || pa.y + ch <= pb.y || pb.y + ch <= pa.y
                        if !separated { violations.append("overlap \(tag) \(a),\(b)") }
                    }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
    }

    @Test("5: the frame inside each cell has the source aspect, to within rounding")
    func aspectErrorIsBounded() {
        var violations: [String] = []
        for p in sweep() {
            let inset = max(0, Int(p.spacing.rounded()) - 4)
            let fw = Double(Int(p.layout.thumbnailSize.width) - inset)
            let fh = Double(Int(p.layout.thumbnailSize.height) - inset)
            let relative = abs(fw / fh - Double(p.aspect)) / Double(p.aspect)
            // Rounding the height to whole pixels costs at most half a pixel; frames are >= 40 px.
            if relative > 0.5 / fh + 1e-9 || relative > 0.0125 + 1e-9 { violations.append("\(p.rows)x\(p.columns) s=\(p.aspect) W=\(p.width) sp=\(p.spacing): \(relative)") }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
    }

    @Test("6: the width is a maximum; the height respects the texture limit")
    func widthIsAMaximum() {
        var violations: [String] = []
        for p in sweep() {
            let canvasW = Int(p.layout.mosaicSize.width), canvasH = Int(p.layout.mosaicSize.height)
            if canvasW > p.width || canvasH > 16_384 { violations.append("bounds \(p.rows)x\(p.columns) s=\(p.aspect) W=\(p.width)") }
            let reduced = p.notes.contains(.widthReduced(from: p.width, to: canvasW))
            if (canvasW < p.width) != reduced { violations.append("note \(p.rows)x\(p.columns) W=\(p.width) canvas=\(canvasW)") }
            // Trimmed to whole cells: less than `columns` pixels short, unless the height limit shrank it.
            if p.width - canvasW >= p.columns, canvasH + 4 * p.rows + 200 < 16_384 { violations.append("trim \(p.rows)x\(p.columns) W=\(p.width) canvas=\(canvasW)") }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")

        // A poster column: 10 rows of 16:9 at 5120 px would be 28,800 px tall (spec G4).
        guard case .layout(let poster, let effective, let notes) = plan(10, 1) else { Issue.record("10 x 1 should be feasible"); return }
        #expect(Int(poster.mosaicSize.height) <= 16_384)
        #expect(effective < 3_000 && effective > 2_800, "Width shrinks to about 2,880 (got \(effective))")
        #expect(notes == [.widthReduced(from: 5120, to: effective)])
        // The reserved overlay height comes off the texture limit.
        guard case .layout(let reserved, _, _) = plan(10, 1, reserved: 600) else { Issue.record("feasible"); return }
        #expect(Int(reserved.mosaicSize.height) <= 16_384 - 600)
        #expect(reserved.mosaicSize.width < poster.mosaicSize.width)
    }

    @Test("7: deterministic, with golden positions")
    func determinismAndGoldens() throws {
        let first = plan(3, 4, aspect: 16.0 / 9, width: 1200)
        let second = plan(3, 4, aspect: 16.0 / 9, width: 1200)
        let fresh = plan(3, 4, aspect: 16.0 / 9, width: 1200, processor: LayoutProcessor())
        func layoutOf(_ plan: FixedGridPlan) throws -> MosaicLayout {
            guard case .layout(let layout, _, _) = plan else { throw MosaicError.invalidConfiguration("infeasible") }
            return layout
        }
        let a = try layoutOf(first), b = try layoutOf(second), c = try layoutOf(fresh)
        for other in [b, c] {
            #expect(a.positions.map(\.x) == other.positions.map(\.x) && a.positions.map(\.y) == other.positions.map(\.y))
            #expect(a.thumbnailSizes == other.thumbnailSizes && a.mosaicSize == other.mosaicSize)
        }

        // 297 x 167 cells (297 / (16/9) = 167.06), canvas 1200 x 509.
        #expect(a.thumbnailSize == CGSize(width: 297, height: 167))
        #expect(a.positions.map(\.x) == [0, 301, 602, 903, 0, 301, 602, 903, 0, 301, 602, 903])
        #expect(a.positions.map(\.y) == [0, 0, 0, 0, 171, 171, 171, 171, 342, 342, 342, 342])
        #expect(a.mosaicSize == CGSize(width: 1200, height: 509))

        // A 9:16 source in 3 columns: 330 x 587 cells; the width loses 2 px to whole cells.
        guard case .layout(let portrait, let portraitWidth, let portraitNotes) = plan(2, 3, aspect: 9.0 / 16, width: 1000) else { throw MosaicError.invalidConfiguration("infeasible") }
        #expect(portrait.thumbnailSize == CGSize(width: 330, height: 587))
        #expect(portrait.mosaicSize == CGSize(width: 998, height: 1178))
        #expect(portraitWidth == 998 && portraitNotes == [.widthReduced(from: 1000, to: 998)])

        // Spacing 12 insets every frame by 8 px; the cell height compensates (388 / (4/3) = 291).
        guard case .layout(let spaced, _, _) = plan(4, 6, aspect: 4.0 / 3, width: 2400, spacing: 12) else { throw MosaicError.invalidConfiguration("infeasible") }
        #expect(spaced.thumbnailSize == CGSize(width: 396, height: 299))
        #expect(spaced.mosaicSize == CGSize(width: 2396, height: 1208))
    }

    @Test("8: cells are in row-major order, time ascending")
    func rowMajorOrder() throws {
        guard case .layout(let layout, _, _) = plan(5, 7, aspect: 4.0 / 3, width: 3000) else { throw MosaicError.invalidConfiguration("infeasible") }
        for (index, position) in layout.positions.enumerated() {
            let row = index / 7, column = index % 7
            #expect(position.x == column * (Int(layout.thumbnailSize.width) + 4))
            #expect(position.y == row * (Int(layout.thumbnailSize.height) + 4))
            if index > 0 {
                let previous = layout.positions[index - 1]
                #expect(position.y > previous.y || (position.y == previous.y && position.x > previous.x))
            }
        }
    }

    // MARK: - LayoutProcessor wiring

    @Test("9: the layout cache keeps grids that differ in any input apart")
    func cacheSeparatesGrids() {
        let processor = LayoutProcessor()
        func layout(_ grid: GridSpecification, spacing: CGFloat = 4, reserved: Int = 0, width: Int = 3000) -> MosaicLayout {
            processor.calculateLayout(
                originalAspectRatio: 16.0 / 9.0, mosaicAspectRatio: .widescreen, thumbnailCount: grid.rows * grid.columns,
                mosaicWidth: width, density: .m, layoutType: .fixedGrid, grid: grid, spacing: spacing, reservedHeight: reserved
            )
        }
        let base = GridSpecification(rows: 3, columns: 4)
        let first = layout(base)
        #expect(first.rows == 3 && first.cols == 4)
        // The same call is a cache hit, and gives the same answer.
        #expect(layout(base).thumbnailSizes == first.thumbnailSizes)
        // Different rows, columns, spacing or reserved height must not return the first entry.
        #expect(layout(GridSpecification(rows: 4, columns: 3)).rows == 4)
        #expect(layout(GridSpecification(rows: 3, columns: 5)).cols == 5)
        #expect(layout(base, spacing: 12).thumbnailSize != first.thumbnailSize)
        #expect(layout(GridSpecification(rows: 12, columns: 1), reserved: 0).mosaicSize.height != layout(GridSpecification(rows: 12, columns: 1), reserved: 12_000).mosaicSize.height)
        // The key of an existing layout is unchanged: asking for it afterwards still works.
        #expect(!processor.calculateLayout(
            originalAspectRatio: 16.0 / 9.0, mosaicAspectRatio: .widescreen, thumbnailCount: 24,
            mosaicWidth: 3000, density: .m, layoutType: .custom
        ).positions.isEmpty)
    }

    @Test("14: the frame count of a grid is rows × columns, even for a short video, whatever the density")
    func thumbnailCountOfAGrid() {
        let processor = LayoutProcessor()
        let grid = GridSpecification(rows: 6, columns: 10)
        for duration in [3.0, 5, 60, 7200] {
            for density in [DensityConfig.xxl, .m, .xxs] {
                #expect(processor.calculateThumbnailCount(duration: duration, width: 5120, density: density, layoutType: .fixedGrid, videoAR: 16.0 / 9, grid: grid) == 60)
            }
        }
        #expect(processor.calculateThumbnailCount(duration: 60, width: 5120, density: .m, layoutType: .fixedGrid, videoAR: 16.0 / 9, grid: nil) == 0)
        // Invalid inputs keep returning 0, as for every layout.
        #expect(processor.calculateThumbnailCount(duration: .nan, width: 5120, density: .m, layoutType: .fixedGrid, videoAR: 16.0 / 9, grid: grid) == 0)
        // Other layouts are unaffected by the new parameter.
        #expect(processor.calculateThumbnailCount(duration: 3, width: 5120, density: .m, layoutType: .custom, videoAR: 16.0 / 9) == 4)
    }

    @Test("A fixed grid wins over forIphone, and nothing else changes")
    func effectiveLayoutTypes() {
        func config(_ type: LayoutType) -> MosaicConfiguration {
            MosaicConfiguration(width: 1600, layout: LayoutConfiguration(layoutType: type, grid: GridSpecification(rows: 2, columns: 3)))
        }
        #expect(MetalMosaicGenerator.effectiveLayoutType(config: config(.fixedGrid), forIphone: true) == .fixedGrid)
        #expect(MetalMosaicGenerator.effectiveLayoutType(config: config(.fixedGrid), forIphone: false) == .fixedGrid)
        for type in [LayoutType.custom, .classic, .auto, .iphone] {
            #expect(MetalMosaicGenerator.effectiveLayoutType(config: config(type), forIphone: true) == .iphone)
            #expect(MetalMosaicGenerator.effectiveLayoutType(config: config(type), forIphone: false) == type)
        }
    }

    @Test("The reserved height covers the header and the ColorDNA strip")
    func reservedHeight() {
        var config = MosaicConfiguration(width: 5120, layout: .fixedGrid(rows: 2, columns: 3))
        config.includeMetadata = false
        #expect(MetalMosaicGenerator.fixedGridReservedHeight(for: config) == 0)
        config.includeMetadata = true
        #expect(MetalMosaicGenerator.fixedGridReservedHeight(for: config) == 512 + 32)
        config.overlay.colorDNA = ColorDNAConfig(show: true, height: 24)
        #expect(MetalMosaicGenerator.fixedGridReservedHeight(for: config) == 512 + 32 + 24)
    }

    // MARK: - Integration (embedded media, kept small)

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "mp4"), "Missing test fixture \(name).mp4")
    }

    private func gridConfig(rows: Int, columns: Int, width: Int = 1200, outputDirectory: URL? = nil) -> MosaicConfiguration {
        var config = MosaicConfiguration(
            width: width, density: .xxl, format: .jpeg,
            layout: .fixedGrid(rows: rows, columns: columns),
            includeMetadata: false, useAccurateTimestamps: false, compressionQuality: 0.5,
            outputdirectory: outputDirectory
        )
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        return config
    }

    @Test("A 3 × 4 grid of test_video.mp4 comes out at the planned size")
    func mosaicImageMatchesThePlan() async throws {
        let video = try await VideoInput(from: try fixture("test_video"))
        let config = gridConfig(rows: 3, columns: 4)
        let generator = try MetalMosaicGenerator()
        let image = try await generator.generateMosaicImage(for: video, config: config)

        guard case .layout(let planned, _, _) = LayoutProcessor().planFixedGrid(
            try #require(config.layout.grid), sourceAspectRatio: (video.width ?? 1) / (video.height ?? 1),
            mosaicAspectRatio: config.layout.aspectRatio, mosaicWidth: config.width
        ) else { throw MosaicError.invalidConfiguration("infeasible") }
        #expect(image.width == Int(planned.mosaicSize.width) && image.height == Int(planned.mosaicSize.height))
        #expect(planned.positions.count == 12)
    }

    @Test("A portrait clip gets portrait cells")
    func portraitSourceGetsPortraitCells() async throws {
        let video = try await VideoInput(from: try fixture("rotated_portrait"))
        let config = gridConfig(rows: 2, columns: 3, width: 900)
        let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
        // 360 x 640 source: three columns of 9:16 cells are taller than wide, so is the canvas.
        #expect(image.height > image.width)
        #expect(image.width <= 900 && image.width > 890)
    }

    @Test("forIphone keeps the user's grid")
    func forIphoneKeepsTheGrid() async throws {
        let video = try await VideoInput(from: try fixture("test_video"))
        let config = gridConfig(rows: 2, columns: 2, width: 1600)
        let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config, forIphone: true)
        // The iPhone layout is a fixed 1200 px wide; the grid asked for (up to) 1600.
        #expect(image.width > 1500 && image.width <= 1600, "Got \(image.width)")
    }

    @Test("A grid that cannot be laid out is rejected before anything is written")
    func infeasibleGridFailsBeforeDecoding() async throws {
        // Unknown dimensions: a grid cannot guess the source aspect.
        let url = try fixture("test_video")
        let video = VideoInput(canonicalID: UUID(), url: url, title: "No size", duration: 60, width: nil, height: nil)
        await #expect(throws: MosaicError.self) {
            try await MetalMosaicGenerator().generateMosaicImage(for: video, config: gridConfig(rows: 2, columns: 2))
        }
    }

    @Test("The animation backfill uses the same grid as the mosaic")
    func backfillUsesTheGrid() async throws {
        let video = try await VideoInput(from: try fixture("test_video"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitGridBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = gridConfig(rows: 2, columns: 3, outputDirectory: folder)
        let generator = try MetalMosaicGenerator()
        // First run writes the mosaic only.
        let mosaicURL = try await generator.generate(for: video, config: config)
        #expect(FileManager.default.fileExists(atPath: mosaicURL.path))

        // Second run: the mosaic exists, the animation does not, so only the animation is backfilled.
        config.gifMode = .withMosaic
        config.gifSize = .small
        config.animatedFormat = .gif
        _ = try await generator.generate(for: video, config: config)
        let animationURL = config.animatedOutputURL(for: video)
        let source = try #require(CGImageSourceCreateWithURL(animationURL as CFURL, nil), "No animation at \(animationURL.lastPathComponent)")
        #expect(CGImageSourceGetCount(source) == 6, "The backfilled animation must have rows × columns frames")
    }
}
