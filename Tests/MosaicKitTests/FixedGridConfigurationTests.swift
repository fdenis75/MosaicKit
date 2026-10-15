import Foundation
import Testing
@testable import MosaicKit

/// The `fixedGrid` layout's model, validation and output identity (plan step G-1; spec
/// `codebase-analysis-docs/specs/SPEC_FIXED_GRID_LAYOUT.md`, sections 2.2 to 2.4).
struct FixedGridConfigurationTests {

    private func config(
        width: Int = 5120,
        grid: GridSpecification? = GridSpecification(rows: 6, columns: 8),
        layoutType: LayoutType = .fixedGrid,
        aspectRatio: AspectRatio = .widescreen,
        spacing: CGFloat = 4
    ) -> MosaicConfiguration {
        MosaicConfiguration(
            width: width, density: .m, format: .jpeg,
            layout: LayoutConfiguration(aspectRatio: aspectRatio, spacing: spacing, layoutType: layoutType, grid: grid)
        )
    }

    /// The message of the `invalidConfiguration` error `validate()` throws, or `nil` when it does not throw it.
    private func validationMessage(_ config: MosaicConfiguration) -> String? {
        do { try config.validate() } catch MosaicError.invalidConfiguration(let message) { return message } catch { return "other: \(error)" }
        return nil
    }

    // MARK: - Types and Codable

    @Test("The new layout type is persisted as fixedGrid and listed")
    func layoutTypeCase() throws {
        #expect(LayoutType.fixedGrid.rawValue == "fixedGrid")
        #expect(LayoutType.allCases.contains(.fixedGrid))
        #expect(LayoutType.allCases.count == 5)
        #expect(try JSONDecoder().decode(LayoutType.self, from: Data(#""fixedGrid""#.utf8)) == .fixedGrid)
    }

    @Test("A GridSpecification round-trips, and keys added later decode with defaults")
    func gridSpecificationCodable() throws {
        let original = GridSpecification(rows: 4, columns: 6, fit: .letterbox, aspectTolerance: 0.05, minimumFill: 0.7)
        let decoded = try JSONDecoder().decode(GridSpecification.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)

        let minimal = try JSONDecoder().decode(GridSpecification.self, from: Data(#"{"rows":3,"columns":5}"#.utf8))
        #expect(minimal == GridSpecification(rows: 3, columns: 5))
        #expect(minimal.fit == .adaptCanvas && minimal.aspectTolerance == 0.02 && minimal.minimumFill == 0.5)

        #expect(GridFitMode.allCases.map(\.rawValue) == ["adaptCanvas", "letterbox", "crop", "stretch"])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GridSpecification.self, from: Data(#"{"rows":3}"#.utf8)) }
    }

    @Test("LayoutConfiguration carries the grid, and the convenience builds a fixedGrid layout")
    func layoutConfigurationGrid() throws {
        let layout = LayoutConfiguration.fixedGrid(rows: 4, columns: 6, fit: .stretch, aspectRatio: .standard, spacing: 8)
        #expect(layout.layoutType == .fixedGrid)
        #expect(layout.grid == GridSpecification(rows: 4, columns: 6, fit: .stretch))
        #expect(layout.aspectRatio == .standard && layout.spacing == 8)
        #expect(try JSONDecoder().decode(LayoutConfiguration.self, from: JSONEncoder().encode(layout)).grid == layout.grid)
        #expect(LayoutConfiguration.default.grid == nil)
    }

    @Test("Saved configurations decode unchanged and re-encode without a grid key")
    func legacyPayloadsStayGridFree() throws {
        for name in ["mosaic-config-1.0.0", "mosaic-config-1.3.2", "mosaic-config-1.7.0", "mosaic-config-legacy-minimal"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"), "Missing fixture \(name)")
            let decoded = try JSONDecoder().decode(MosaicConfiguration.self, from: Data(contentsOf: url))
            #expect(decoded.layout.grid == nil, "\(name)")
            let reencoded = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
            #expect(!reencoded.contains("grid"), "\(name) re-encodes a grid key")
        }
    }

    // MARK: - Output identity

    @Test("Existing layouts keep exactly the hashes they had")
    func existingHashesAreUnchanged() {
        for layoutType in [LayoutType.custom, .classic, .auto, .iphone] {
            #expect(config(grid: nil, layoutType: layoutType).configurationHash == "5120_M_16-9_\(layoutType.rawValue)")
        }
        // A grid left on a non-grid layout is ignored by the hash.
        #expect(config(grid: GridSpecification(rows: 3, columns: 3), layoutType: .classic).configurationHash == "5120_M_16-9_classic")
    }

    @Test("Golden hash forms for fixedGrid")
    func goldenHashes() {
        #expect(config().configurationHash == "5120_M_16-9_fixedGrid-6x8-sp4")
        let letterbox = GridSpecification(rows: 6, columns: 8, fit: .letterbox)
        #expect(config(grid: letterbox).configurationHash == "5120_M_16-9_fixedGrid-6x8-letterbox-tol0.02-sp4")
        let crop = GridSpecification(rows: 2, columns: 3, fit: .crop, aspectTolerance: 0.035)
        #expect(config(grid: crop, aspectRatio: .vertical, spacing: 12).configurationHash == "5120_M_9-16_fixedGrid-2x3-crop-tol0.035-sp12")
        // Spacing below the 4 px gutter behaves as 4; fractions are kept exactly, because the
        // renderer insets every cell by the exact value.
        #expect(config(spacing: 0).configurationHash.hasSuffix("-sp4"))
        #expect(config(spacing: 7.5).configurationHash.hasSuffix("-sp7.5"))
        #expect(config(spacing: 6.6).configurationHash != config(spacing: 7.4).configurationHash)
        #expect(config(spacing: 6.6).configurationHash.hasSuffix("-sp6.6") && config(spacing: 7.4).configurationHash.hasSuffix("-sp7.4"))
    }

    @Test("Every output-affecting grid parameter is in the hash; the ones that are not read are not")
    func hashSensitivity() {
        let base = config().configurationHash
        #expect(config(grid: GridSpecification(rows: 8, columns: 6)).configurationHash != base)
        #expect(config(grid: GridSpecification(rows: 6, columns: 9)).configurationHash != base)
        #expect(config(spacing: 12).configurationHash != base)
        #expect(config(grid: GridSpecification(rows: 6, columns: 8, fit: .letterbox)).configurationHash != base)

        // adaptCanvas never reads the tolerance or the minimum fill.
        #expect(config(grid: GridSpecification(rows: 6, columns: 8, aspectTolerance: 0.1)).configurationHash == base)
        #expect(config(grid: GridSpecification(rows: 6, columns: 8, minimumFill: 0.9)).configurationHash == base)

        // A fixed-aspect mode reads the tolerance, but minimumFill only accepts or rejects a request.
        let stretch = config(grid: GridSpecification(rows: 6, columns: 8, fit: .stretch)).configurationHash
        #expect(config(grid: GridSpecification(rows: 6, columns: 8, fit: .stretch, aspectTolerance: 0.1)).configurationHash != stretch)
        #expect(config(grid: GridSpecification(rows: 6, columns: 8, fit: .stretch, minimumFill: 0.9)).configurationHash == stretch)
    }

    @Test("The {layout} template token carries the grid, so file names never collide")
    func layoutTemplateToken() {
        let video = VideoInput(canonicalID: UUID(), url: URL(fileURLWithPath: "/tmp/clip.mp4"), title: "clip")
        var small = config()
        small.filenameTemplate = "{name}_{layout}"
        small.outputDirectoryTemplate = "{root}/{layout}"
        var wide = small
        wide.layout.grid = GridSpecification(rows: 6, columns: 9)

        #expect(small.generateFilename(originalFilename: "clip", videoInput: video).hasPrefix("clip_fixedGrid-6x8-sp4"))
        #expect(wide.generateFilename(originalFilename: "clip", videoInput: video).hasPrefix("clip_fixedGrid-6x9-sp4"))
        let root = URL(fileURLWithPath: "/tmp/out")
        #expect(small.generateOutputDirectory(rootDirectory: root, videoInput: video).lastPathComponent == "fixedGrid-6x8-sp4")
        #expect(small.animatedOutputURL(for: video).lastPathComponent.contains("fixedGrid-6x8-sp4"))
    }

    // MARK: - Validation

    @Test("Configurations that are not grids validate exactly as before")
    func nonGridLayoutsStillValidate() throws {
        for layoutType in [LayoutType.custom, .classic, .auto, .iphone] {
            try config(grid: nil, layoutType: layoutType).validate()
        }
        try config(grid: GridSpecification(rows: 0, columns: 0), layoutType: .classic).validate()
    }

    @Test("Each invalid grid is rejected with the cause and the numbers", arguments: [
        (GridSpecification(rows: 0, columns: 4), "between 1 and 50 rows and columns (got 0 × 4)"),
        (GridSpecification(rows: -1, columns: 3), "(got -1 × 3)"),
        (GridSpecification(rows: 1, columns: 90), "(got 1 × 90)"),
        (GridSpecification(rows: 40, columns: 40), "at most 1000 cells (40 × 40 is 1600)"),
        (GridSpecification(rows: 3, columns: 3, aspectTolerance: 0.3), "tolerance"),
        (GridSpecification(rows: 3, columns: 3, aspectTolerance: .nan), "tolerance"),
        (GridSpecification(rows: 3, columns: 3, minimumFill: 0.05), "minimum fill"),
        (GridSpecification(rows: 3, columns: 3, minimumFill: .infinity), "minimum fill"),
    ])
    func invalidGrids(grid: GridSpecification, fragment: String) {
        let message = validationMessage(config(grid: grid))
        #expect(message?.contains(fragment) == true, "got: \(message ?? "no error")")
    }

    @Test("A fixedGrid layout without a grid is rejected")
    func missingGrid() {
        #expect(validationMessage(config(grid: nil))?.contains("needs LayoutConfiguration.grid") == true)
    }

    @Test("Animated exports need at least 4 cells")
    func animationNeedsFourCells() {
        var animated = config(grid: GridSpecification(rows: 1, columns: 3))
        animated.gifMode = .withMosaic
        animated.animatedFormat = .gif
        #expect(validationMessage(animated)?.contains("at least 4 cells (a 1 × 3 grid has 3)") == true)
        animated.layout.grid = GridSpecification(rows: 2, columns: 2)
        #expect(validationMessage(animated)?.contains("not available") == true, "4 cells pass the animation rule")
    }

    @Test("An astronomically large spacing is rejected, not a crash")
    func hugeSpacingDoesNotTrap() {
        for spacing in [CGFloat(1e12), CGFloat(Double(Int.max)), CGFloat.greatestFiniteMagnitude] {
            let message = validationMessage(config(spacing: spacing))
            #expect(message?.contains("leave frames") == true, "spacing \(spacing): \(message ?? "no error")")
        }
        // The hash of such a configuration is still computable.
        #expect(config(spacing: .greatestFiniteMagnitude).configurationHash.contains("fixedGrid-6x8-sp"))
    }

    @Test("Too many columns for the width name the limit")
    func columnFloor() {
        // (1000 - 29 * 4) / 30 = 29 px per frame.
        let narrow = validationMessage(config(width: 1000, grid: GridSpecification(rows: 2, columns: 30)))
        #expect(narrow?.contains("30 columns at width 1000 leave frames 29 px wide") == true, "got: \(narrow ?? "no error")")
        #expect(narrow?.contains("at most 22 columns") == true, "got: \(narrow ?? "no error")")
        // Extra spacing eats into the frame: 12 px spacing is an 8 px inset on 64 px cells.
        let spaced = validationMessage(config(width: 2000, grid: GridSpecification(rows: 2, columns: 30), spacing: 40))
        #expect(spaced?.contains("leave frames") == true)
        // Exactly 40 px passes this rule: (1000 - 4 * 4) / 5 = 196, and the fixed-aspect row rule is separate.
        #expect(validationMessage(config(width: 1000, grid: GridSpecification(rows: 2, columns: 5)))?.contains("not available") == true)
    }

    @Test("Fixed-aspect modes also need tall enough frames; adaptCanvas leaves the height to the planner")
    func rowFloor() {
        // A 16:9 canvas of width 2000 is 1125 px tall: (1125 - 49 * 4) / 50 = 18 px per frame.
        let letterbox = validationMessage(config(width: 2000, grid: GridSpecification(rows: 50, columns: 2, fit: .letterbox)))
        #expect(letterbox?.contains("50 rows in a 16:9 canvas of width 2000 leave frames 18 px tall") == true, "got: \(letterbox ?? "no error")")
        let adapt = validationMessage(config(width: 2000, grid: GridSpecification(rows: 50, columns: 2)))
        #expect(adapt?.contains("not available") == true, "got: \(adapt ?? "no error")")
    }

    @Test("A valid grid is refused for now, in every entry point, before any decode")
    func validGridIsNotAvailableYet() async throws {
        let message = validationMessage(config())
        #expect(message == "The fixedGrid layout is not available in this build yet")

        let url = try #require(Bundle.module.url(forResource: "test_video", withExtension: "mp4"))
        let video = try await VideoInput(from: url)
        let generator = try MetalMosaicGenerator()
        await #expect(throws: MosaicError.self) { try await generator.generateMosaicImage(for: video, config: config(width: 1200)) }
        await #expect(throws: MosaicError.self) { try await generator.generate(for: video, config: config(width: 1200)) }
    }

    // MARK: - No silent fall-through

    @Test("fixedGrid never produces a custom layout, and does not poison the layout cache")
    func neverFallsThroughToCustom() {
        let processor = LayoutProcessor()
        func layout(_ type: LayoutType) -> MosaicLayout {
            processor.calculateLayout(
                originalAspectRatio: 16.0 / 9.0, mosaicAspectRatio: .widescreen, thumbnailCount: 24,
                mosaicWidth: 2000, density: .m, layoutType: type
            )
        }
        let grid = layout(.fixedGrid)
        #expect(grid.positions.isEmpty && grid.thumbCount == 0 && grid.mosaicSize == .zero)
        #expect(!layout(.custom).positions.isEmpty)
        #expect(layout(.fixedGrid).positions.isEmpty, "Asking for custom in between must not change the answer")
    }
}
