import Foundation
import AVFoundation
import CoreGraphics
import Testing
@testable import MosaicKit

/// Rotated (portrait phone) sources — implementation plan P-2a, knowledge base I-1.
///
/// `embeddedAsset/rotated_portrait.mp4` is an 8-second, 8-bit H.264 clip whose samples are
/// 640×360 with a 90° track transform, so it displays as 360×640 like a portrait phone video.
///
/// Frame extraction honours the rotation (portrait frames), and since F-1 (I-1) inspection
/// reports the display size (`naturalSize` with `preferredTransform` applied), so the layout
/// gets portrait cells and frames are not stretched.
struct RotatedSourceTests {

    private var fixtureURL: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "rotated_portrait", withExtension: "mp4"),
                         "Missing test fixture rotated_portrait.mp4")
        }
    }

    @Test("Extracted frames of a rotated source are upright (portrait)")
    func extractedFramesArePortrait() async throws {
        let url = try fixtureURL
        let frames = try await ThumbnailProcessor(config: .default).extractFramesForGif(
            from: url, asset: AVURLAsset(url: url), count: 2, gifSize: .nochange
        )
        let frame = try #require(frames.first)
        #expect(frame.height > frame.width, "Frame is \(frame.width)×\(frame.height)")
    }

    @Test("Inspection reports display dimensions for a rotated source (I-1)")
    func inspectionReportsDisplayDimensions() async throws {
        let video = try await VideoInput(from: try fixtureURL)
        let width = try #require(video.width)
        let height = try #require(video.height)

        let layout = LayoutProcessor().calculateLayout(
            originalAspectRatio: width / height,
            mosaicAspectRatio: .widescreen,
            thumbnailCount: 12,
            mosaicWidth: 2000,
            density: .m,
            layoutType: .classic
        )

        #expect(width == 360 && height == 640, "Inspected size is \(width)×\(height); the clip displays as 360×640")
        #expect(layout.thumbnailSize.height > layout.thumbnailSize.width,
                "Classic layout cells are \(layout.thumbnailSize); portrait frames would be stretched into them")
    }
}
