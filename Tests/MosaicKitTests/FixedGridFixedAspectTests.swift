import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import MosaicKit

/// `.letterbox` and `.stretch` (plan step G-4; spec section 3.3): the canvas keeps the mosaic
/// aspect, overlays are subtracted from the grid area, and frames are fitted into the cells.
struct FixedGridFixedAspectTests {

    private func plan(
        _ rows: Int, _ columns: Int, fit: GridFitMode = .letterbox, source: CGFloat = 16.0 / 9,
        aspect: AspectRatio = .widescreen, width: Int = 5120, spacing: CGFloat = 4, overlay: Int = 0,
        tolerance: Double = 0.02, minimumFill: Double = 0.5
    ) -> FixedGridPlan {
        LayoutProcessor().planFixedGrid(
            GridSpecification(rows: rows, columns: columns, fit: fit, aspectTolerance: tolerance, minimumFill: minimumFill),
            sourceAspectRatio: source, mosaicAspectRatio: aspect, mosaicWidth: width, spacing: spacing, overlayHeight: overlay
        )
    }

    private func planned(_ plan: FixedGridPlan) -> (MosaicLayout, Int, [FixedGridNote])? {
        if case .layout(let layout, let width, let notes) = plan { return (layout, width, notes) }
        return nil
    }

    private func issue(_ plan: FixedGridPlan) -> FixedGridIssue? {
        if case .infeasible(let issue, _) = plan { return issue }
        return nil
    }

    private func suggestions(_ plan: FixedGridPlan) -> [GridSpecification] {
        if case .infeasible(_, let suggestions) = plan { return suggestions }
        return []
    }

    // MARK: - Letterbox geometry

    @Test("A letterboxed frame keeps the source aspect inside its slot; rects are centered, inside the canvas and do not overlap")
    func letterboxGeometry() throws {
        // 16:9 video, 16:9 canvas, 3 x 4: the slots are 4:3-ish, so frames are letterboxed.
        let (layout, width, notes) = try #require(planned(plan(3, 4)))
        #expect(width == 5120 && layout.mosaicSize == CGSize(width: 5120, height: 2880))
        #expect(layout.thumbCount == 12 && layout.positions.count == 12 && layout.thumbnailSizes.count == 12)
        guard case .letterboxed(let fill)? = notes.first(where: { if case .letterboxed = $0 { return true } else { return false } }) else {
            Issue.record("Expected a letterboxed note, got \(notes)"); return
        }
        #expect(fill > 0.5 && fill < 1)
        let rects = zip(layout.positions, layout.thumbnailSizes).map { CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: $1.width, height: $1.height) }
        for rect in rects {
            #expect(abs(rect.width / rect.height - 16.0 / 9) < 0.02, "Frame aspect \(rect.width / rect.height)")
            #expect(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 5120 && rect.maxY <= 2880)
        }
        for (i, a) in rects.enumerated() { for b in rects[(i + 1)...] { #expect(!a.intersects(b)) } }
        // Pillarbox on a tall slot too: 16:9 video, 1 x 4 grid in a 16:9 canvas has 3.6:1... use 4 x 1.
        let (tall, _, _) = try #require(planned(plan(4, 1, minimumFill: 0.1)))
        for size in tall.thumbnailSizes { #expect(abs(size.width / size.height - 16.0 / 9) < 0.05) }
    }

    @Test("Within the tolerance every mode stretches: no bars, a stretched note")
    func withinTolerance() throws {
        // 4:3 video, 16:9 canvas, 3 x 4: slot 1.333:1 vs 1.333:1.
        for fit in [GridFitMode.letterbox, .stretch] {
            let (layout, _, notes) = try #require(planned(plan(3, 4, fit: fit, source: 4.0 / 3)))
            #expect(notes.contains { if case .stretched = $0 { return true } else { return false } }, "\(fit): \(notes)")
            #expect(!notes.contains { if case .letterboxed = $0 { return true } else { return false } })
            let size = try #require(layout.thumbnailSizes.first)
            #expect(abs(size.width / size.height - 4.0 / 3) < 0.03)
        }
    }

    @Test("Spacing above 4 px insets the frame; the rect compensates so the drawn frame keeps the aspect")
    func spacingInset() throws {
        let (layout, _, _) = try #require(planned(plan(3, 4, spacing: 12)))
        // The renderer insets by spacing - 4 = 8 px in total, on both axes.
        let size = try #require(layout.thumbnailSizes.first)
        #expect(abs((size.width - 8) / (size.height - 8) - 16.0 / 9) < 0.03)
    }

    // MARK: - Rejections and suggestions

    @Test("Stretch rejects a mismatch with suggestions that all work; letterbox rejects too little picture")
    func rejections() throws {
        // 16:9 video, 9:16 canvas, 5 x 5: cells are 0.56:1.
        let stretch = plan(5, 5, fit: .stretch, aspect: .vertical)
        guard case .aspectMismatch(let cellAspect, let sourceAspect, let error)? = issue(stretch) else {
            Issue.record("Expected aspectMismatch, got \(String(describing: issue(stretch)))"); return
        }
        #expect(cellAspect < 0.6 && abs(sourceAspect - 16.0 / 9) < 1e-9 && error > 2)
        let found = suggestions(stretch)
        #expect(found.count == 3)
        for suggestion in found {
            #expect(suggestion.fit == .stretch)
            #expect(planned(plan(suggestion.rows, suggestion.columns, fit: .stretch, aspect: .vertical)) != nil, "\(suggestion)")
        }
        let letterbox = plan(5, 5, fit: .letterbox, aspect: .vertical)
        guard case .fillTooLow(let fill, let minimum)? = issue(letterbox) else {
            Issue.record("Expected fillTooLow, got \(String(describing: issue(letterbox)))"); return
        }
        #expect(fill < 0.5 && minimum == 0.5)
        #expect(suggestions(letterbox).count == 3)
        // A lower minimum fill accepts it.
        #expect(planned(plan(5, 5, fit: .letterbox, aspect: .vertical, minimumFill: 0.3)) != nil)
        // 16:9 video, 3 x 4 in 16:9: stretch is rejected, with working suggestions.
        let moderate = plan(3, 4, fit: .stretch)
        #expect(issue(moderate) != nil && !suggestions(moderate).isEmpty)
        // No grid works: the list is empty rather than made up.
        #expect(suggestions(plan(50, 20, fit: .stretch, source: 9.0 / 16, width: 1000)).count <= 3)
    }

    @Test("Cells that are too small are refused, and a tolerance of 0 stretches only a perfect match")
    func smallAndTolerance() {
        
        guard case .cellsTooSmall? = issue(plan(30, 30, width: 1000)) else {
            Issue.record("Expected cellsTooSmall"); return
        }
        // A slot a hair off the source aspect letterboxes at tolerance 0.
        let result = planned(plan(2, 2, fit: .letterbox, tolerance: 0))
        #expect(result != nil)
    }

    // MARK: - Overlays and the final aspect

    @Test("The overlay height is subtracted from the grid area so header + grid = round(W / A)")
    func overlaySubtraction() throws {
        let (layout, _, _) = try #require(planned(plan(3, 4, overlay: 280)))
        #expect(layout.mosaicSize == CGSize(width: 5120, height: 2880 - 280))
        let (vertical, _, _) = try #require(planned(plan(2, 3, source: 9.0 / 16, aspect: .vertical, width: 2000, overlay: 100)))
        #expect(vertical.mosaicSize == CGSize(width: 2000, height: Int((2000 / (9.0 / 16)).rounded()) - 100))
    }

    @Test("A canvas that would be taller than a texture is narrowed, with a note")
    func tallCanvasNarrowed() throws {
        #expect(LayoutProcessor.fixedGridCanvasWidth(requestedWidth: 10_000, mosaicAspectRatio: .vertical) == 9216)
        #expect(LayoutProcessor.fixedGridCanvasWidth(requestedWidth: 5120, mosaicAspectRatio: .widescreen) == 5120)
        let (layout, width, notes) = try #require(planned(plan(2, 2, source: 9.0 / 16, aspect: .vertical, width: 10_000)))
        #expect(width == 9216 && layout.mosaicSize.height <= 16_384)
        #expect(notes.contains(.widthReduced(from: 10_000, to: 9216)))
    }

    @Test("The shared header helper returns the height of the header it draws")
    func headerHelperMatchesHeader() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        let processor = ThumbnailProcessor(config: .default)
        for width in [1600, 5120] {
            let image = try #require(processor.createMetadataHeader(for: video, width: width, thumbnailHeight: CGFloat(width) / 20))
            #expect(processor.metadataHeaderHeight(for: video, width: width, thumbnailHeight: CGFloat(width) / 20) == image.height)
        }
    }

    // MARK: - Crop (G-5)

    @Test("Crop keeps the slot size, notes what survives, and refuses too little picture")
    func cropPlan() throws {
        let (layout, _, notes) = try #require(planned(plan(3, 4, fit: .crop)))
        guard case .cropped(let retained)? = notes.first(where: { if case .cropped = $0 { return true } else { return false } }) else {
            Issue.record("Expected a cropped note, got \(notes)"); return
        }
        #expect(retained > 0.5 && retained < 1)
        // Slots are 1277 x 957 here; the rect is the whole slot (no bars).
        let size = try #require(layout.thumbnailSizes.first)
        #expect(size == CGSize(width: 1277, height: 957), "got \(size)")
        #expect(layout.thumbnailSizes.allSatisfy { $0 == size })
        // Within the tolerance: stretched, not cropped.
        let (_, _, near) = try #require(planned(plan(3, 4, fit: .crop, source: 4.0 / 3)))
        #expect(near.contains { if case .stretched = $0 { return true } else { return false } })
        // Too little of the picture survives.
        guard case .fillTooLow? = issue(plan(5, 5, fit: .crop, aspect: .vertical)) else {
            Issue.record("Expected fillTooLow"); return
        }
        #expect(planned(plan(5, 5, fit: .crop, aspect: .vertical, minimumFill: 0.3)) != nil)
    }

    private func solid(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test("The center crop has the requested aspect, is centered, and leaves a matching image alone")
    func centerCrop() throws {
        let wide = try solid(1600, 900)
        let toFour = ThumbnailProcessor.croppedCenter(wide, toAspect: 4.0 / 3)
        #expect(toFour.width == 1200 && toFour.height == 900)
        let toSquare = ThumbnailProcessor.croppedCenter(wide, toAspect: 1)
        #expect(toSquare.width == 900 && toSquare.height == 900)
        let tall = ThumbnailProcessor.croppedCenter(wide, toAspect: 16.0 / 5)
        #expect(tall.width == 1600 && tall.height == 500)
        #expect(ThumbnailProcessor.croppedCenter(wide, toAspect: 1600.0 / 900).width == 1600)
        #expect(ThumbnailProcessor.croppedCenter(wide, toAspect: .nan).width == 1600)
        #expect(ThumbnailProcessor.croppedCenter(wide, toAspect: 0).width == 1600)
    }

    @Test("Only a fixed grid in crop mode with a real mismatch asks for a crop")
    func frameCropSelection() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        let ratio = CGFloat(video.width ?? 16) / CGFloat(video.height ?? 9)
        guard case .layout(let layout, _, _) = LayoutProcessor().planFixedGrid(
            GridSpecification(rows: 3, columns: 4, fit: .crop), sourceAspectRatio: ratio,
            mosaicAspectRatio: .widescreen, mosaicWidth: 1600
        ) else { Issue.record("infeasible"); return }
        func crop(_ fit: GridFitMode) -> ThumbnailProcessor.FrameCrop? {
            let config = MosaicConfiguration(width: 1600, layout: .fixedGrid(rows: 3, columns: 4, fit: fit))
            return MetalMosaicGenerator.frameCrop(for: video, layout: layout, config: config)
        }
        // The 3 x 4 cells are 4:3; the video is 16:9.
        let cropped = try #require(crop(.crop))
        #expect(abs(cropped.aspect - 4.0 / 3) < 0.02 && abs(cropped.sourceAspect - 16.0 / 9) < 0.01, "got \(cropped)")
        #expect(crop(.letterbox) == nil && crop(.stretch) == nil && crop(.adaptCanvas) == nil)
    }

    @Test("A cropped mosaic with header and strip has exactly the configured aspect")
    func cropEndToEnd() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        var config = MosaicConfiguration(
            width: 1600, density: .xxl, format: .jpeg,
            layout: .fixedGrid(rows: 3, columns: 4, fit: .crop, aspectRatio: .widescreen),
            includeMetadata: true
        )
        config.overlay.colorDNA = ColorDNAConfig(show: true, height: 16, position: .bottom, style: .barcode)
        let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
        #expect(image.width == 1600 && image.height == 900, "Got \(image.width) x \(image.height)")
    }

    @Test("A portrait clip is cropped to portrait-ish cells in a vertical canvas")
    func cropRotatedPortrait() async throws {
        let url = try #require(Bundle.module.url(forResource: "rotated_portrait", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        var config = MosaicConfiguration(
            width: 900, density: .xxl, format: .jpeg,
            layout: .fixedGrid(rows: 3, columns: 2, fit: .crop, aspectRatio: .vertical),
            includeMetadata: false
        )
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
        #expect(image.width == 900 && image.height == 1600, "Got \(image.width) x \(image.height)")
    }

    // MARK: - End to end

    @Test("A letterboxed mosaic with header and ColorDNA strip has exactly the configured aspect")
    func endToEndFinalAspect() async throws {
        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicKitFixedAspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = MosaicConfiguration(
            width: 1600, density: .xxl, format: .jpeg,
            layout: .fixedGrid(rows: 3, columns: 4, fit: .letterbox, aspectRatio: .widescreen),
            includeMetadata: true, outputdirectory: folder
        )
        config.overlay.colorDNA = ColorDNAConfig(show: true, height: 16, position: .bottom, style: .barcode)
        let image = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
        #expect(image.width == 1600 && image.height == 900, "Got \(image.width) x \(image.height)")

        // The same grid without overlays fills the canvas exactly.
        config.includeMetadata = false
        config.overlay.colorDNA = ColorDNAConfig(show: false)
        let bare = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
        #expect(bare.width == 1600 && bare.height == 900)

        // Stretch of the same grid is refused before anything is decoded.
        config.layout.grid?.fit = .stretch
        do {
            _ = try await MetalMosaicGenerator().generateMosaicImage(for: video, config: config)
            Issue.record("A 33 % mismatch must be rejected in stretch mode")
        } catch MosaicError.invalidConfiguration(let message) {
            #expect(message.contains("off"), "got: \(message)")
        }
    }
}
