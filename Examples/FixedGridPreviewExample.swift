//
//  FixedGridPreviewExample.swift
//  MosaicKit
//
//  A live preview of a fixed rows × columns grid, drawn from `LayoutProcessor.planFixedGrid`.
//  The planner is pure and cheap, so it can run on every change of a stepper or picker: the
//  rectangles it returns are the ones the generator will render, so the preview equals the output.
//

import SwiftUI
import MosaicKit

struct FixedGridPreview: View {
    /// The grid being edited.
    var grid: GridSpecification
    /// `VideoInput.aspectRatio` of the video (width / height).
    var sourceAspectRatio: Double
    var mosaicAspectRatio: AspectRatio = .widescreen
    var mosaicWidth: Int = 5120
    /// Fixed-aspect modes (`.letterbox`, `.stretch`, `.crop`): the exact height of the header plus
    /// the ColorDNA strip. Compute it with `ThumbnailProcessor(config:).metadataHeaderHeight(for:
    /// video, width: LayoutProcessor.fixedGridCanvasWidth(requestedWidth:mosaicAspectRatio:),
    /// thumbnailHeight: width / 20)` and add `ColorDNAConfig.height` when the strip is shown.
    /// `.adaptCanvas` ignores it.
    var overlayHeight: Int = 0

    private var plan: FixedGridPlan {
        LayoutProcessor().planFixedGrid(
            grid,
            sourceAspectRatio: CGFloat(sourceAspectRatio),
            mosaicAspectRatio: mosaicAspectRatio,
            mosaicWidth: mosaicWidth,
            overlayHeight: overlayHeight
        )
    }

    var body: some View {
        switch plan {
        case .layout(let layout, let effectiveWidth, let notes):
            VStack(alignment: .leading, spacing: 8) {
                canvas(for: layout)
                Text("\(effectiveWidth) × \(Int(layout.mosaicSize.height) + headerHeight) px")
                    .font(.caption)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(describe(note)).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .infeasible(let issue, let suggestions):
            VStack(alignment: .leading, spacing: 8) {
                Text(issue.explanation).foregroundStyle(.red)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, grid in
                    Text("Try \(grid.rows) × \(grid.columns)").font(.caption)
                }
            }
        }
    }

    /// The header band above the grid: only the fixed-aspect modes subtract it from the canvas.
    private var headerHeight: Int { grid.fit == .adaptCanvas ? 0 : max(overlayHeight, 0) }

    /// The canvas scaled to the view, the header band on top, one rectangle per frame.
    private func canvas(for layout: MosaicLayout) -> some View {
        let totalHeight = layout.mosaicSize.height + CGFloat(headerHeight)
        return Canvas { context, size in
            let scale = min(size.width / layout.mosaicSize.width, size.height / totalHeight)
            context.fill(Path(CGRect(x: 0, y: 0, width: layout.mosaicSize.width * scale,
                                     height: totalHeight * scale)), with: .color(.black))
            if headerHeight > 0 {
                context.fill(Path(CGRect(x: 0, y: 0, width: layout.mosaicSize.width * scale,
                                         height: CGFloat(headerHeight) * scale)), with: .color(.gray.opacity(0.4)))
            }
            for (index, position) in layout.positions.enumerated() {
                let frameSize = layout.thumbnailSizes[index]
                let rect = CGRect(x: CGFloat(position.x) * scale,
                                  y: (CGFloat(position.y) + CGFloat(headerHeight)) * scale,
                                  width: frameSize.width * scale,
                                  height: frameSize.height * scale)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.7)))
                context.draw(Text("\(index + 1)").font(.caption2), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        .aspectRatio(layout.mosaicSize.width / totalHeight, contentMode: .fit)
    }

    private func describe(_ note: FixedGridNote) -> String {
        switch note {
        case .widthReduced(let from, let to): return "Width reduced from \(from) to \(to) px"
        case .stretched(let error): return String(format: "Frames stretched by %.1f %%", error * 100)
        case .letterboxed(let fill): return String(format: "Frames fill %.0f %% of each cell", fill * 100)
        case .cropped(let retained): return String(format: "%.0f %% of each frame is kept", retained * 100)
        }
    }
}

/// A small editor around the preview: change rows, columns and the fit mode, and watch the plan.
struct FixedGridEditor: View {
    @State private var rows = 4
    @State private var columns = 6
    @State private var fit: GridFitMode = .adaptCanvas

    var body: some View {
        Form {
            Stepper("Rows: \(rows)", value: $rows, in: 1...GridSpecification.maximumAxisCount)
            Stepper("Columns: \(columns)", value: $columns, in: 1...GridSpecification.maximumAxisCount)
            Picker("Fit", selection: $fit) {
                ForEach(GridFitMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            FixedGridPreview(
                grid: GridSpecification(rows: rows, columns: columns, fit: fit),
                sourceAspectRatio: 16.0 / 9.0
            )
        }
        .padding()
    }
}

/// Generating the mosaic with the grid the editor shows. The preview above passes no overlay
/// height, so the header and the ColorDNA strip are turned off here: the output then has exactly
/// the previewed cells. To keep them, compute `overlayHeight` as described on
/// `FixedGridPreview.overlayHeight` and pass the same value to the preview.
func generateFixedGridMosaic(
    grid: GridSpecification,
    videoURL: URL,
    outputDirectory: URL
) async throws -> URL {
    let video = try await VideoInput(from: videoURL)
    var config = MosaicConfiguration(width: 5120, format: .heif, includeMetadata: false)
    config.layout = LayoutConfiguration(aspectRatio: .widescreen, layoutType: .fixedGrid, grid: grid)
    config.overlay.colorDNA.show = false
    config.outputdirectory = outputDirectory
    // Before any frame is decoded, an infeasible grid throws `MosaicError.invalidConfiguration`
    // with the planner's explanation, and a video that cannot fill it (unknown dimensions, fewer
    // distinct frames than cells) throws `MosaicError.invalidVideo`.
    return try await MetalMosaicGenerator().generate(for: video, config: config)
}

#Preview {
    FixedGridEditor()
}
