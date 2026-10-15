import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

/// The uneven-tiles packer (plan step U-1; spec
/// `codebase-analysis-docs/specs/SPEC_UNEVEN_TILES_LAYOUT.md`, §4 and §11).
///
/// Pure geometry: no media, no GPU. The property tests sweep source aspects, target aspects,
/// widths, counts and spans, and collect violations so a failure prints the first few.
struct UnevenTilePackerTests {

    private struct Case {
        let source: Double, target: Double, width: Int, count: Int, span: Int
        let plan: UnevenTilePacker.Plan
        let layout: MosaicLayout
        var label: String { "a=\(source) A=\(target) W=\(width) N=\(count) x=\(span)" }
    }

    private static let sweep: [Case] = {
        let sources: [Double] = [16.0 / 9, 9.0 / 16, 21.0 / 9]
        let targets: [Double] = AspectRatio.allCases.map { Double($0.ratio) }
        var cases: [Case] = []
        for source in sources {
            for target in targets {
                for width in [2000, 5120] {
                    for count in [4, 12, 30, 107, 400] {
                        for span in [2, 3, 5] {
                            let plan = UnevenTilePacker.plan(
                                sourceAspect: source, targetAspect: target, width: width, count: count, maxSpan: span
                            )
                            let layout = UnevenTilePacker.layout(for: plan, width: width, sourceAspect: source)
                            cases.append(Case(source: source, target: target, width: width, count: count,
                                              span: span, plan: plan, layout: layout))
                        }
                    }
                }
            }
        }
        return cases
    }()

    private func report(_ violations: [String], of total: Int) -> Comment {
        "\(violations.count) of \(total) cases: \(violations.prefix(5).joined(separator: "; "))"
    }

    /// Cell owners: the index of the tile covering each unit cell, or `nil` when a cell is
    /// covered twice, left empty, or a tile leaves the lattice.
    private func owners(_ plan: UnevenTilePacker.Plan) -> [Int]? {
        var owner = [Int](repeating: -1, count: plan.cols * plan.rows)
        for (index, tile) in plan.tiles.enumerated() {
            guard tile.col >= 0, tile.row >= 0, tile.span >= 1,
                  tile.col + tile.span <= plan.cols, tile.row + tile.span <= plan.rows else { return nil }
            for r in tile.row..<(tile.row + tile.span) {
                for c in tile.col..<(tile.col + tile.span) {
                    guard owner[r * plan.cols + c] == -1 else { return nil }
                    owner[r * plan.cols + c] = index
                }
            }
        }
        return owner.contains(-1) ? nil : owner
    }

    // MARK: - Coverage and geometry

    @Test("Exact coverage: every unit cell is covered by exactly one tile")
    func exactCoverage() {
        var violations: [String] = []
        for c in Self.sweep {
            let area = c.plan.tiles.reduce(0) { $0 + $1.span * $1.span }
            if owners(c.plan) == nil || area != c.plan.cols * c.plan.rows { violations.append(c.label) }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("Pixel rects stay inside the canvas, the width is exact and neighbours are one gutter apart")
    func pixelGeometry() {
        var violations: [String] = []
        for c in Self.sweep {
            guard let owner = owners(c.plan) else { violations.append("coverage \(c.label)"); continue }
            let (gx, gy) = UnevenTilePacker.gutters(sourceAspect: c.source)
            let canvas = c.layout.mosaicSize
            if Int(canvas.width) != c.width { violations.append("width \(c.label)") }
            let rects = zip(c.layout.positions, c.layout.thumbnailSizes).map {
                CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: $1.width, height: $1.height)
            }
            if rects.contains(where: { $0.minX < 0 || $0.minY < 0 || $0.maxX > canvas.width || $0.maxY > canvas.height || $0.width < 1 }) {
                violations.append("outside \(c.label)")
            }
            let (cols, rows) = (c.plan.cols, c.plan.rows)
            for r in 0..<rows {
                for col in 0..<cols {
                    let here = owner[r * cols + col]
                    if col + 1 < cols, owner[r * cols + col + 1] != here {
                        let gap = rects[owner[r * cols + col + 1]].minX - rects[here].maxX
                        if gap < CGFloat(gx.rounded(.down)) || gap > CGFloat(gx.rounded(.up)) {
                            violations.append("h-gap \(gap) \(c.label)")
                        }
                    }
                    if r + 1 < rows, owner[(r + 1) * cols + col] != here {
                        let gap = rects[owner[(r + 1) * cols + col]].minY - rects[here].maxY
                        if gap < CGFloat(gy.rounded(.down)) || gap > CGFloat(gy.rounded(.up)) {
                            violations.append("v-gap \(gap) \(c.label)")
                        }
                    }
                }
            }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("Every tile keeps the source aspect: within 2 px for 98 % of tiles, 4 px for all")
    func sourceAspectPreserved() {
        var tiles = 0, over2 = 0
        var violations: [String] = []
        for c in Self.sweep {
            for size in c.layout.thumbnailSizes {
                let error = abs(Double(size.width) - Double(size.height) * c.source)
                tiles += 1
                if error > 2 { over2 += 1 }
                if error > 4 { violations.append("\(error) px \(c.label)") }
            }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
        #expect(Double(over2) <= 0.02 * Double(tiles), "\(over2) of \(tiles) tiles are more than 2 px off")
    }

    // MARK: - Counts, sizes and aspect

    @Test("The tile count is near the request from 30 frames up, unless a cap binds")
    func counts() {
        var violations: [String] = []
        for c in Self.sweep {
            let l = c.layout
            if l.thumbCount != c.plan.tiles.count || l.positions.count != l.thumbCount || l.thumbnailSizes.count != l.thumbCount {
                violations.append("mismatch \(c.label)")
            }
            if c.count >= 30, !c.plan.capped, abs(Double(c.plan.tiles.count - c.count)) / Double(c.count) > 0.25 {
                violations.append("\(c.plan.tiles.count) tiles \(c.label)")
            }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("Spans stay within the grid's limit, every allowed size appears, and a span is k unit cells")
    func sizeClasses() {
        var violations: [String] = []
        for c in Self.sweep {
            let p = c.plan
            if p.maxSpan > c.span || p.maxSpan > max(1, min(p.cols, p.rows) / 2) || p.maxSpan < 1 {
                violations.append("maxSpan \(p.maxSpan) \(c.label)")
            }
            if p.tiles.contains(where: { $0.span > p.maxSpan }) { violations.append("span over limit \(c.label)") }
            if c.count >= 30, !p.capped, Set(p.tiles.map(\.span)) != Set(1...p.maxSpan) {
                violations.append("classes \(Set(p.tiles.map(\.span)).sorted()) of \(p.maxSpan) \(c.label)")
            }
            let (gx, _) = UnevenTilePacker.gutters(sourceAspect: c.source)
            let unit = (Double(c.width) - Double(p.cols - 1) * gx) / Double(p.cols)
            for (tile, size) in zip(p.tiles, c.layout.thumbnailSizes) {
                let expected = Double(tile.span) * unit + Double(tile.span - 1) * gx
                if abs(Double(size.width) - expected) > 1 { violations.append("width \(size.width) vs \(expected) \(c.label)") }
            }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("From 100 frames up the canvas is within 2 % of the target aspect, unless a cap binds")
    func canvasAspect() {
        var violations: [String] = []
        for c in Self.sweep where c.count >= 100 && !c.plan.capped {
            let aspect = Double(c.layout.mosaicSize.width / c.layout.mosaicSize.height)
            if abs(aspect / c.target - 1) > 0.02 { violations.append("\(aspect) \(c.label)") }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("Documented worst cases keep their known values (spec §8)")
    func documentedCases() {
        // Case 4: portrait source in a 16:9 mosaic.
        let portrait = UnevenTilePacker.plan(sourceAspect: 9.0 / 16, targetAspect: 16.0 / 9, width: 5120, count: 107, maxSpan: 3)
        #expect((portrait.cols, portrait.rows, portrait.tiles.count) == (22, 7, 106))
        // Case 10: the first count with a larger tile.
        let small = UnevenTilePacker.plan(sourceAspect: 16.0 / 9, targetAspect: 16.0 / 9, width: 5120, count: 12, maxSpan: 3)
        #expect(small.maxSpan == 2)
        #expect(small.tiles.contains { $0.span == 2 })
        // Case 9: four frames fit no larger tile.
        let tiny = UnevenTilePacker.plan(sourceAspect: 16.0 / 9, targetAspect: 16.0 / 9, width: 5120, count: 4, maxSpan: 3)
        #expect(tiny.maxSpan == 1)
        #expect(tiny.tiles.allSatisfy { $0.span == 1 })
    }

    // MARK: - Determinism and order

    @Test("Tiles are in reading order and start at the top-left cell")
    func readingOrder() {
        var violations: [String] = []
        for c in Self.sweep {
            let tiles = c.plan.tiles
            if tiles.first.map({ ($0.col, $0.row) != (0, 0) }) ?? true { violations.append("first \(c.label)") }
            if zip(tiles, tiles.dropFirst()).contains(where: { ($0.row, $0.col) >= ($1.row, $1.col) }) {
                violations.append("order \(c.label)")
            }
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("Same inputs give the same plan")
    func determinism() {
        for c in Self.sweep.prefix(60) {
            let again = UnevenTilePacker.plan(sourceAspect: c.source, targetAspect: c.target, width: c.width, count: c.count, maxSpan: c.span)
            #expect(again == c.plan, "\(c.label)")
        }
    }

    struct Golden: Sendable, CustomTestStringConvertible {
        let source: Double, target: Double, count: Int, span: Int
        let cols: Int, rows: Int, tiles: Int
        /// Larger tiles as `col,row,span`; the 1×1 tiles fill every other cell.
        let heroes: String
        var testDescription: String { "a=\(source) A=\(target) N=\(count) x=\(span)" }
    }

    static let goldens: [Golden] = [
        Golden(source: 16.0 / 9, target: 16.0 / 9, count: 107, span: 3, cols: 13, rows: 13, tiles: 107,
               heroes: "2,0,2 9,0,3 0,1,2 6,2,2 11,3,2 1,4,3 4,4,2 6,6,2 9,6,3 0,7,2 6,8,2 9,9,2 1,10,3 4,10,2"),
        Golden(source: 16.0 / 9, target: 16.0 / 9, count: 26, span: 2, cols: 6, rows: 6, tiles: 27,
               heroes: "3,0,2 2,2,2 0,4,2"),
        Golden(source: 21.0 / 9, target: 21.0 / 9, count: 429, span: 5, cols: 27, rows: 27, tiles: 429,
               heroes: "18,0,2 24,0,3 1,1,5 6,1,4 11,1,2 16,1,2 14,2,2 19,2,3 12,4,2 25,5,2 1,6,2 3,6,3 7,6,4 "
                   + "23,7,2 0,9,2 3,9,3 12,9,4 16,9,2 19,9,2 21,9,5 0,11,3 16,11,2 16,13,2 8,14,3 12,14,4 "
                   + "19,14,2 5,15,2 25,16,2 5,17,3 17,17,5 23,17,2 0,18,4 8,18,2 10,19,2 13,19,3 11,21,2 "
                   + "19,22,4 23,22,3 0,23,2 12,23,2"),
        Golden(source: 9.0 / 16, target: 16.0 / 9, count: 107, span: 3, cols: 22, rows: 7, tiles: 106,
               heroes: "4,0,3 11,0,2 20,0,2 16,1,2 7,2,2 12,2,3 4,3,2 6,4,2 9,4,3 20,4,2 17,5,2"),
    ]

    /// Pinned so any change to the packer is deliberate: once released, the output of a
    /// configuration must not move (spec Q-U7). The M 16:9 case is the spec's §4.2 example.
    @Test("Golden layouts at 5120 px", arguments: goldens)
    func golden(_ pinned: Golden) {
        let plan = UnevenTilePacker.plan(sourceAspect: pinned.source, targetAspect: pinned.target, width: 5120,
                                         count: pinned.count, maxSpan: pinned.span)
        #expect(plan.cols == pinned.cols)
        #expect(plan.rows == pinned.rows)
        #expect(plan.tiles.count == pinned.tiles)
        let larger = plan.tiles.filter { $0.span > 1 }.map { "\($0.col),\($0.row),\($0.span)" }
        #expect(larger.joined(separator: " ") == pinned.heroes)
    }

    // MARK: - Limits and odd input

    @Test("The canvas never exceeds the height limit and the unit tile stays at least 120 px wide")
    func limits() {
        let tall = UnevenTilePacker.plan(sourceAspect: 16.0 / 9, targetAspect: 9.0 / 16, width: 10_000, count: 400, maxSpan: 3,
                                         maximumHeight: 16_384 - 1_032)
        let tallLayout = UnevenTilePacker.layout(for: tall, width: 10_000, sourceAspect: 16.0 / 9)
        #expect(tall.capped)
        #expect(tallLayout.mosaicSize.height <= 16_384 - 1_032)
        #expect(owners(tall) != nil)

        let narrow = UnevenTilePacker.plan(sourceAspect: 16.0 / 9, targetAspect: 16.0 / 9, width: 2000, count: 800, maxSpan: 5)
        let narrowLayout = UnevenTilePacker.layout(for: narrow, width: 2000, sourceAspect: 16.0 / 9)
        #expect(narrow.capped)
        #expect(narrowLayout.thumbnailSize.width >= 120)
        #expect(narrow.tiles.count < 800)

        var violations: [String] = []
        for c in Self.sweep where c.layout.mosaicSize.height > 16_384 || c.layout.thumbnailSize.width < 120 {
            violations.append(c.label)
        }
        #expect(violations.isEmpty, report(violations, of: Self.sweep.count))
    }

    @Test("Huge counts are clamped to the packer's maximum")
    func hugeCount() {
        let plan = UnevenTilePacker.plan(sourceAspect: 16.0 / 9, targetAspect: 16.0 / 9, width: 16_384, count: 100_000, maxSpan: 8)
        #expect(owners(plan) != nil)
        #expect(plan.tiles.count <= Int(Double(UnevenTilePacker.maximumCount) * 1.25))
    }

    struct OddInput: Sendable {
        let source: Double, target: Double, width: Int, count: Int, span: Int
    }

    static let oddInputs: [OddInput] = [
        OddInput(source: .nan, target: 16.0 / 9, width: 5120, count: 30, span: 3),
        OddInput(source: 16.0 / 9, target: 0, width: 5120, count: 30, span: 3),
        OddInput(source: 16.0 / 9, target: 16.0 / 9, width: 0, count: 30, span: 3),
        OddInput(source: 16.0 / 9, target: 16.0 / 9, width: 5120, count: 0, span: 3),
        OddInput(source: 16.0 / 9, target: 16.0 / 9, width: 5120, count: 30, span: 0),
        OddInput(source: 16.0 / 9, target: 16.0 / 9, width: 5120, count: 30, span: 100),
        OddInput(source: 50, target: 1, width: 5120, count: 30, span: 3),
        OddInput(source: 0.02, target: 1, width: 5120, count: 30, span: 3),
    ]

    @Test("Odd input still gives a covered lattice", arguments: oddInputs)
    func oddInput(_ input: OddInput) {
        let plan = UnevenTilePacker.plan(sourceAspect: input.source, targetAspect: input.target, width: input.width,
                                         count: input.count, maxSpan: input.span)
        #expect(owners(plan) != nil)
        #expect(!plan.tiles.isEmpty)
        #expect(plan.maxSpan <= UnevenTilePacker.maximumSpan)
    }
}
