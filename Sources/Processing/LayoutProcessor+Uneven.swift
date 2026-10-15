import Foundation
import CoreGraphics

extension LayoutProcessor {

    /// Below this many frames ``LayoutType/uneven`` uses the classic layout: a lattice that small
    /// holds no larger tile and misses the target aspect badly (spec §8 cases 2 and 9, Q-U5).
    static let unevenMinimumCount = 12

    /// Source aspects ``LayoutType/uneven`` lays out; outside them the lattice degenerates to one
    /// row or column, so the classic layout is used (spec §8 case 8).
    static let unevenSourceAspects: ClosedRange<CGFloat> = 0.2...5

    /// The largest tile side, in unit cells, until frames are extracted at their own tile size
    /// (plan step U-3, spec Q-U6): a frame decoded for a larger tile and shrunk 3× or more by the
    /// GPU's bilinear sampler aliases.
    static let unevenSpanCap = 2

    /// The largest tile side for a density (spec §4.2): `XXL`/`XL` 2, `L`/`M` 3, `S`/`XS` 4,
    /// `XXS` 5. Read from the density factor, so custom densities get the nearest level's value.
    static func unevenMaxSpan(for density: DensityConfig) -> Int {
        switch density.factor {
        case ..<0.625: return 2
        case ..<1.5: return 3
        case ..<3.5: return 4
        default: return 5
        }
    }

    /// The ``LayoutType/uneven`` layout: a bento grid whose larger tiles are whole multiples of
    /// the smallest, so no frame is cropped or distorted. Called under the processor's lock.
    ///
    /// - Parameters:
    ///   - reservedHeight: Upper bound of the header and ColorDNA strip height, subtracted from
    ///     the texture limit so the final image stays within it.
    func calculateUnevenLayout(
        originalAspectRatio: CGFloat,
        mosaicAspectRatio: AspectRatio,
        thumbnailCount: Int,
        mosaicWidth: Int,
        density: DensityConfig,
        reservedHeight: Int
    ) -> MosaicLayout {
        guard thumbnailCount >= Self.unevenMinimumCount, Self.unevenSourceAspects.contains(originalAspectRatio) else {
            logger.info("Uneven layout needs at least \(Self.unevenMinimumCount) frames and a source aspect within 0.2…5 (got \(thumbnailCount) frames, aspect \(originalAspectRatio)); using the classic layout")
            return calculateClassicLayout(
                originalAspectRatio: originalAspectRatio, thumbnailCount: thumbnailCount, mosaicWidth: mosaicWidth
            )
        }
        let state = signposter.beginInterval("Uneven Layout")
        defer { signposter.endInterval("Uneven Layout", state) }

        let span = min(Self.unevenMaxSpan(for: density), Self.unevenSpanCap)
        let plan = UnevenTilePacker.plan(
            sourceAspect: Double(originalAspectRatio), targetAspect: Double(mosaicAspectRatio.ratio),
            width: mosaicWidth, count: thumbnailCount, maxSpan: span,
            maximumHeight: Self.maximumCanvasSide - max(reservedHeight, 0)
        )
        if plan.capped {
            logger.info("Uneven layout capped by the 120 px tile floor or the texture height: \(plan.tiles.count) tiles for \(thumbnailCount) requested, \(plan.cols)×\(plan.rows) cells")
        }
        if plan.maxSpan < span {
            logger.debug("Uneven layout: the \(plan.cols)×\(plan.rows) grid allows tiles up to \(plan.maxSpan)×, not \(span)×")
        }
        return UnevenTilePacker.layout(for: plan, width: mosaicWidth, sourceAspect: Double(originalAspectRatio))
    }
}
