import Foundation
import CoreGraphics

/// Packs tiles of several sizes into a "bento" grid for the uneven-tiles layout (plan step U-1;
/// spec `codebase-analysis-docs/specs/SPEC_UNEVEN_TILES_LAYOUT.md`, §4).
///
/// The canvas is a `cols × rows` lattice of unit cells that have the source aspect ratio. A tile
/// is a `span × span` block of cells, so every tile has the source aspect too: no frame is
/// cropped or distorted at any size. 1×1 tiles fill every hole, so coverage is exact by
/// construction. The packer only decides the lattice and where the larger tiles go.
///
/// Pure and deterministic: integer scheduling, a golden-ratio sequence and arrays indexed by
/// span, never a hash or a random source. The same inputs give the same tiles on every run and
/// machine. Freeze the output once it ships: tests pin golden layouts (spec Q-U7).
struct UnevenTilePacker: Sendable {

    /// One tile: its top-left unit cell and its side in cells.
    struct Tile: Equatable, Sendable {
        var col: Int
        var row: Int
        var span: Int
    }

    /// The lattice and the tiles, in reading order (sorted by row, then column).
    struct Plan: Equatable, Sendable {
        var cols: Int
        var rows: Int
        /// The largest span the grid allows (`x_eff`), at most the requested one.
        var maxSpan: Int
        var tiles: [Tile]
        /// A cap bound: the height limit shortened the lattice (so the canvas misses the target
        /// aspect), or the unit-width floor left fewer cells than the requested count needs.
        var capped: Bool
    }

    /// The larger gutter, between cells along the source's longer side. The other gutter is
    /// scaled by the source aspect so a span of cells keeps the source aspect (spec §4.5).
    static let gutter = 4.0
    /// The narrowest unit tile, so frame labels stay readable (spec §8 case 16).
    static let minimumUnitWidth = 120.0
    /// The largest tile count the packer lays out; larger requests are clamped (spec §8 case 11).
    static let maximumCount = 5_000
    /// The largest span the packer accepts.
    static let maximumSpan = 8
    /// Share of the canvas area given to spans of 2 and more, split equally between them.
    static let heroAreaShare = 0.45
    /// Larger tiles never cover more than this share of the cells.
    static let maximumHeroAreaShare = 0.6
    /// Number of placement passes; the best-balanced one is kept.
    static let seedCount = 8

    private static let phi = 0.6180339887
    /// Hero quotas fall due by this share of the area, so the last rows can still take them.
    private static let endSlack = 0.92

    /// Horizontal and vertical gutters for a source aspect: the larger one is ``gutter`` and
    /// their ratio is the source aspect, so a `k × k` tile has the source aspect exactly.
    static func gutters(sourceAspect: Double) -> (horizontal: Double, vertical: Double) {
        sourceAspect >= 1 ? (gutter, gutter / sourceAspect) : (gutter * sourceAspect, gutter)
    }

    /// Plans the lattice and the tiles.
    ///
    /// - Parameters:
    ///   - sourceAspect: The video's display aspect ratio (width / height).
    ///   - targetAspect: The mosaic's aspect ratio; the lattice gets as close as its cells allow.
    ///   - width: The canvas width in pixels; it is used exactly.
    ///   - count: The requested tile count, a target (clamped to `1...maximumCount`).
    ///   - maxSpan: The largest tile side in cells (clamped to `1...maximumSpan`); the grid may
    ///     allow less (`Plan.maxSpan`).
    ///   - maximumHeight: The tallest canvas allowed; rows are dropped to stay below it.
    static func plan(
        sourceAspect: Double, targetAspect: Double, width: Int, count: Int, maxSpan: Int,
        maximumHeight: Int = 16_384
    ) -> Plan {
        let a = sourceAspect.isFinite && sourceAspect > 0 ? sourceAspect : 16.0 / 9.0
        let target = targetAspect.isFinite && targetAspect > 0 ? targetAspect : a
        let w = Double(max(width, 1))
        let n = min(max(count, 1), maximumCount)
        let (gx, gy) = gutters(sourceAspect: a)
        let maxCols = max(1, Int(((w + gx) / (minimumUnitWidth + gx)).rounded(.down)))
        let heightLimit = Double(max(maximumHeight, 1))

        var span = min(max(maxSpan, 1), maximumSpan)
        var grid = chooseGrid(
            cells: Double(n) / tilesPerCell(span), sourceAspect: a, targetAspect: target, width: w,
            maxCols: maxCols, heightLimit: heightLimit, gutters: (gx, gy)
        )
        // A smaller lattice can hold fewer spans; the mix and so the cell count change with it.
        for _ in 0..<4 {
            let allowed = min(span, max(1, min(grid.cols, grid.rows) / 2))
            if allowed == span { break }
            span = allowed
            grid = chooseGrid(
                cells: Double(n) / tilesPerCell(span), sourceAspect: a, targetAspect: target, width: w,
                maxCols: maxCols, heightLimit: heightLimit, gutters: (gx, gy)
            )
        }
        span = min(span, max(1, min(grid.cols, grid.rows) / 2))

        let cells = grid.cols * grid.rows
        let quota = heroQuotas(cells: cells, count: n, maxSpan: span)
        var best: (score: Double, tiles: [Tile])?
        for seed in 0..<seedCount {
            let tiles = place(cols: grid.cols, rows: grid.rows, maxSpan: span, quota: quota, seed: seed)
            let score = balanceScore(tiles, cols: grid.cols, rows: grid.rows, quota: quota)
            if best == nil || score < best!.score { best = (score, tiles) }
        }
        let tiles = (best?.tiles ?? []).sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        return Plan(cols: grid.cols, rows: grid.rows, maxSpan: span, tiles: tiles, capped: grid.capped)
    }

    /// The pixel layout of a plan: tile edges are rounded from exact cell positions, so
    /// neighbouring tiles are always one gutter apart and the canvas is `width` wide.
    static func layout(for plan: Plan, width: Int, sourceAspect: Double) -> MosaicLayout {
        let a = sourceAspect.isFinite && sourceAspect > 0 ? sourceAspect : 16.0 / 9.0
        let (gx, gy) = gutters(sourceAspect: a)
        let cols = max(plan.cols, 1), rows = max(plan.rows, 1)
        let u = (Double(width) - Double(cols - 1) * gx) / Double(cols)
        let v = u / a
        func left(_ c: Int) -> Int { Int((Double(c) * (u + gx)).rounded()) }
        func right(_ c: Int) -> Int { Int((Double(c) * (u + gx) - gx).rounded()) }
        func top(_ r: Int) -> Int { Int((Double(r) * (v + gy)).rounded()) }
        func bottom(_ r: Int) -> Int { Int((Double(r) * (v + gy) - gy).rounded()) }

        var positions: [(x: Int, y: Int)] = []
        var sizes: [CGSize] = []
        positions.reserveCapacity(plan.tiles.count)
        sizes.reserveCapacity(plan.tiles.count)
        for tile in plan.tiles {
            let x = left(tile.col), y = top(tile.row)
            positions.append((x: x, y: y))
            sizes.append(CGSize(width: right(tile.col + tile.span) - x, height: bottom(tile.row + tile.span) - y))
        }
        return MosaicLayout(
            rows: plan.rows,
            cols: plan.cols,
            thumbnailSize: CGSize(width: u.rounded(), height: v.rounded()),
            positions: positions,
            thumbCount: plan.tiles.count,
            thumbnailSizes: sizes,
            mosaicSize: CGSize(width: width, height: bottom(rows))
        )
    }

    // MARK: - Size mix

    /// Tiles per unit cell for the default mix: spans of 2 and more share ``heroAreaShare`` of
    /// the area equally, span 1 takes the rest.
    static func tilesPerCell(_ maxSpan: Int) -> Double {
        guard maxSpan >= 2 else { return 1 }
        let share = heroAreaShare / Double(maxSpan - 1)
        return (1 - heroAreaShare) + (2...maxSpan).reduce(0) { $0 + share / Double($1 * $1) }
    }

    /// Number of tiles of each span (index = span; 0 and 1 unused) so the tile count lands on
    /// `count`: `tiles = cells − Σ (k² − 1)·n_k`. Starts from the area shares, then adds or
    /// removes single tiles, the least or most served class first, until the count is within 1.
    static func heroQuotas(cells: Int, count: Int, maxSpan: Int) -> [Int] {
        var quota = [Int](repeating: 0, count: maxSpan + 1)
        guard maxSpan >= 2 else { return quota }
        let shareCells = Double(cells) * heroAreaShare / Double(maxSpan - 1)
        for k in 2...maxSpan {
            quota[k] = Int((shareCells / Double(k * k)).rounded())
        }
        let areaCap = Int((Double(cells) * maximumHeroAreaShare).rounded(.down))
        func area() -> Int { (2...maxSpan).reduce(0) { $0 + quota[$1] * $1 * $1 } }
        func fill(_ k: Int) -> Double { Double(quota[k] * k * k) / shareCells }
        // Over the area cap: drop the largest tiles first.
        var k = maxSpan
        while area() > areaCap, k >= 2 {
            if quota[k] > 0 { quota[k] -= 1 } else { k -= 1 }
        }

        let wanted = max(cells - count, 0)
        var residual = wanted - (2...maxSpan).reduce(0) { $0 + quota[$1] * ($1 * $1 - 1) }
        for _ in 0..<(4 * cells + 8) {
            if residual >= 2 {
                let candidates = (2...maxSpan).filter {
                    $0 * $0 - 1 <= residual + 1 && area() + $0 * $0 <= areaCap
                }
                guard let pick = candidates.min(by: { fill($0) < fill($1) }) else { break }
                quota[pick] += 1
                residual -= pick * pick - 1
            } else if residual <= -2 {
                let present = (2...maxSpan).filter { quota[$0] > 0 }
                let fitting = present.filter { residual + $0 * $0 - 1 <= 1 }
                guard let pick = (fitting.isEmpty ? present : fitting).max(by: { fill($0) < fill($1) }) else { break }
                quota[pick] -= 1
                residual += pick * pick - 1
            } else {
                break
            }
        }
        return quota
    }

    // MARK: - Grid choice

    private struct Grid {
        var cols: Int
        var rows: Int
        var capped: Bool
    }

    /// The lattice whose aspect is closest to the target among those near `cells` cells
    /// (spec §4.3), within the unit-width floor and the height limit.
    private static func chooseGrid(
        cells: Double, sourceAspect a: Double, targetAspect target: Double, width w: Double,
        maxCols: Int, heightLimit: Double, gutters: (Double, Double)
    ) -> Grid {
        let (gx, gy) = gutters
        func maxRows(_ c: Int) -> Int {
            let v = (w - Double(c - 1) * gx) / Double(c) / a
            return max(1, Int(((heightLimit + gy) / (v + gy)).rounded(.down)))
        }
        // When the unit-width floor leaves too few columns, aim at the cells of the widest
        // lattice instead: the tile count falls, the canvas aspect does not suffer.
        let widest = Double(maxCols * min(max(Int((Double(maxCols) * a / target).rounded()), 1), maxRows(maxCols)))
        let columnLimited = widest < max(cells, 1)
        let wanted = columnLimited ? widest : max(cells, 1)
        let lastCol = min(maxCols, max(1, Int((1.5 * wanted).rounded(.up))))
        var candidates: [(cols: Int, rows: Int, heightLimited: Bool)] = []
        for c in 1...lastCol {
            let ideal = Double(c) * a / target
            var previous = 0
            for r in [Int(ideal.rounded(.down)), Int(ideal.rounded(.up))] {
                let rows = min(max(r, 1), maxRows(c))
                if rows == previous { continue }
                previous = rows
                candidates.append((c, rows, rows < r))
            }
        }
        var window = 0.2
        while true {
            var best: (score: Double, grid: Grid)?
            for candidate in candidates {
                let cellError = abs(Double(candidate.cols * candidate.rows) - wanted) / wanted
                guard cellError <= window else { continue }
                let aspect = Double(candidate.cols) * a / (Double(candidate.rows) * target)
                let score = abs(aspect - 1) + 0.05 * cellError
                if best == nil || score < best!.score {
                    best = (score, Grid(cols: candidate.cols, rows: candidate.rows,
                                        capped: columnLimited || candidate.heightLimited))
                }
            }
            if let grid = best?.grid { return grid }
            window *= 1.6
        }
    }

    // MARK: - Placement (A1: skyline with error-diffusion scheduling)

    /// Fills the lattice row by row: the lowest, then leftmost free cell gets the largest span
    /// that is due and fits; otherwise a 1×1 tile.
    private static func place(cols: Int, rows: Int, maxSpan: Int, quota: [Int], seed: Int) -> [Tile] {
        let total = cols * rows
        var sky = [Int](repeating: 0, count: cols)
        var placed = [Int](repeating: 0, count: maxSpan + 1)
        let phase = (0...maxSpan).map { 0.5 * frac(Double($0) * phi + Double(seed) * 0.37) }
        var filled = 0
        var tiles: [Tile] = []
        tiles.reserveCapacity(total)
        while filled < total {
            var y = Int.max, c0 = 0
            for c in 0..<cols where sky[c] < y { y = sky[c]; c0 = c }
            var run = 1
            while c0 + run < cols, sky[c0 + run] == y { run += 1 }
            let largest = min(run, rows - y, maxSpan)
            let progress = min(1, Double(filled) / (Double(total) * endSlack))
            var span = 1
            if largest >= 2 {
                for k in stride(from: largest, through: 2, by: -1)
                where placed[k] < quota[k] && Double(quota[k]) * progress + phase[k] - Double(placed[k]) >= 0.5 {
                    span = k
                    break
                }
            }
            var col = c0
            if span > 1 {
                let spread = frac(Double(seed) * 0.37 + Double(tiles.count + 1) * phi + Double(span) * 0.31)
                col = c0 + Int(spread * Double(run - span + 1))
                placed[span] += 1
            }
            for c in col..<(col + span) { sky[c] += span }
            filled += span * span
            tiles.append(Tile(col: col, row: y, span: span))
        }
        return tiles
    }

    /// Lower is better: missed hero quota, and how unevenly the larger tiles spread over the
    /// canvas thirds, its halves and against each other (spec §4.4).
    private static func balanceScore(_ tiles: [Tile], cols: Int, rows: Int, quota: [Int]) -> Double {
        let heroes = tiles.filter { $0.span > 1 }
        let wanted = quota.reduce(0, +)
        let missed = quota.indices.reduce(0) { sum, k in
            sum + max(0, quota[k] - heroes.lazy.filter { $0.span == k }.count)
        }
        let quotaMiss = wanted > 0 ? Double(missed) / Double(wanted) : 0
        guard !heroes.isEmpty else { return 2 * quotaMiss }

        var owner = [Int](repeating: -1, count: cols * rows)
        var colThirds = [0.0, 0.0, 0.0], rowThirds = [0.0, 0.0, 0.0]
        var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0, heroCells = 0.0
        for (index, tile) in tiles.enumerated() where tile.span > 1 {
            for r in tile.row..<(tile.row + tile.span) {
                for c in tile.col..<(tile.col + tile.span) {
                    owner[r * cols + c] = index
                    colThirds[c * 3 / cols] += 1
                    rowThirds[r * 3 / rows] += 1
                    if 2 * c + 1 < cols { left += 1 } else if 2 * c + 1 > cols { right += 1 }
                    if 2 * r + 1 < rows { top += 1 } else if 2 * r + 1 > rows { bottom += 1 }
                    heroCells += 1
                }
            }
        }
        let thirds = (colThirds + rowThirds).map { abs($0 / heroCells - 1.0 / 3) }.max() ?? 0
        let imbalance = (abs(left - right) + abs(top - bottom)) / (2 * heroCells)

        var pairs = Set<Int>()
        for r in 0..<rows {
            for c in 0..<cols {
                let here = owner[r * cols + c]
                guard here >= 0 else { continue }
                for (dr, dc) in [(0, 1), (1, 0)] where r + dr < rows && c + dc < cols {
                    let there = owner[(r + dr) * cols + c + dc]
                    if there >= 0, there != here {
                        pairs.insert(min(here, there) * tiles.count + max(here, there))
                    }
                }
            }
        }
        return 2 * quotaMiss + thirds + 0.5 * imbalance + 0.5 * Double(pairs.count) / Double(heroes.count)
    }

    private static func frac(_ value: Double) -> Double { value - value.rounded(.down) }
}
