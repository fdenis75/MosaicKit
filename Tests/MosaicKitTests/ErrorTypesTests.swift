import Foundation
import CoreGraphics
import Testing
@testable import MosaicKit

/// Verifies that every `LocalizedError` conformance in MosaicKit returns
/// non-nil, non-empty descriptions and (where documented) failure reasons
/// and recovery suggestions.
struct ErrorTypesTests {

    private let sampleURL = URL(fileURLWithPath: "/tmp/sample.mp4")
    private let underlying = NSError(
        domain: "TestDomain", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "underlying test error"]
    )

    // MARK: - MosaicError

    @Test("MosaicError.errorDescription is non-nil and non-empty for every case")
    func mosaicErrorDescriptions() {
        let errors: [MosaicError] = [
            .layoutCreationFailed(underlying),
            .imageGenerationFailed(underlying),
            .saveFailed(sampleURL, underlying),
            .invalidDimensions(CGSize(width: 0, height: 0)),
            .invalidConfiguration("bad config"),
            .generationFailed(underlying),
            .fileExists(sampleURL),
            .contextCreationFailed,
            .imageCreationFailed,
            .invalidVideo("no video track"),
            .metalNotSupported,
            .processingFailed("something broke")
        ]
        for error in errors {
            let desc = error.errorDescription
            #expect(desc != nil,   "\(error): errorDescription is nil")
            #expect(!desc!.isEmpty, "\(error): errorDescription is empty")
        }
    }

    @Test("MosaicError.errorDescription embeds relevant context strings")
    func mosaicErrorDescriptionContext() {
        #expect(MosaicError.invalidVideo("track missing").errorDescription!.contains("track missing"))
        #expect(MosaicError.invalidConfiguration("bad value").errorDescription!.contains("bad value"))
        #expect(MosaicError.processingFailed("out of memory").errorDescription!.contains("out of memory"))
        #expect(MosaicError.saveFailed(sampleURL, underlying).errorDescription!.contains(sampleURL.path))
        #expect(MosaicError.fileExists(sampleURL).errorDescription!.contains(sampleURL.path))
        #expect(MosaicError.invalidDimensions(CGSize(width: 0, height: 0)).errorDescription!.contains("0"))
    }

    // MARK: - LibraryError

    @Test("LibraryError.errorDescription is non-nil and non-empty for every case")
    func libraryErrorDescriptions() {
        let errors: [LibraryError] = [
            .itemCreationFailed("item A"),
            .itemDeletionFailed("item B"),
            .itemMoveFailed("item C"),
            .itemUpdateFailed("item D"),
            .itemNotFound("item E"),
            .operationNotSupported("op F"),
            .operationFailed("op G")
        ]
        for error in errors {
            let desc = error.errorDescription
            #expect(desc != nil,    "\(error): errorDescription is nil")
            #expect(!desc!.isEmpty, "\(error): errorDescription is empty")
        }
    }

    @Test("LibraryError.errorDescription embeds the associated message")
    func libraryErrorDescriptionContext() {
        #expect(LibraryError.itemNotFound("my-item").errorDescription!.contains("my-item"))
        #expect(LibraryError.operationFailed("rename").errorDescription!.contains("rename"))
    }

    // MARK: - VideoError

    @Test("VideoError.errorDescription is non-nil for every case")
    func videoErrorDescriptions() {
        let errors: [VideoError] = [
            .videoTrackNotFound(sampleURL),
            .fileNotFound(sampleURL),
            .accessDenied(sampleURL),
            .invalidFormat(sampleURL),
            .processingFailed(sampleURL, underlying),
            .metadataExtractionFailed(sampleURL, underlying),
            .thumbnailGenerationFailed(sampleURL, underlying),
            .frameExtractionFailed(sampleURL, underlying),
            .cancelled
        ]
        for error in errors {
            let desc = error.errorDescription
            #expect(desc != nil,    "\(error): errorDescription is nil")
            #expect(!desc!.isEmpty, "\(error): errorDescription is empty")
        }
    }

    @Test("VideoError.failureReason is non-nil for every case")
    func videoErrorFailureReasons() {
        let errors: [VideoError] = [
            .videoTrackNotFound(sampleURL), .fileNotFound(sampleURL),
            .accessDenied(sampleURL), .invalidFormat(sampleURL),
            .processingFailed(sampleURL, underlying),
            .metadataExtractionFailed(sampleURL, underlying),
            .thumbnailGenerationFailed(sampleURL, underlying),
            .frameExtractionFailed(sampleURL, underlying),
            .cancelled
        ]
        for error in errors {
            #expect(error.failureReason != nil, "\(error): failureReason is nil")
        }
    }

    @Test("VideoError.recoverySuggestion is non-nil for all non-cancelled cases")
    func videoErrorRecoverySuggestions() {
        let errors: [VideoError] = [
            .videoTrackNotFound(sampleURL), .fileNotFound(sampleURL),
            .accessDenied(sampleURL), .invalidFormat(sampleURL),
            .processingFailed(sampleURL, underlying),
            .metadataExtractionFailed(sampleURL, underlying),
            .thumbnailGenerationFailed(sampleURL, underlying),
            .frameExtractionFailed(sampleURL, underlying)
        ]
        for error in errors {
            #expect(error.recoverySuggestion != nil, "\(error): recoverySuggestion is nil")
        }
        // .cancelled provides a recoverySuggestion as well (it says "Processing cancelled")
        #expect(VideoError.cancelled.recoverySuggestion != nil)
    }

    @Test("VideoError.Equatable: matching cases are equal, differing cases are not")
    func videoErrorEquatable() {
        let url2 = URL(fileURLWithPath: "/tmp/other.mp4")
        #expect(VideoError.fileNotFound(sampleURL) == .fileNotFound(sampleURL))
        #expect(VideoError.cancelled               == .cancelled)
        #expect(VideoError.fileNotFound(sampleURL) != .fileNotFound(url2))
        #expect(VideoError.fileNotFound(sampleURL) != .videoTrackNotFound(sampleURL))
    }

    @Test("VideoError.underlyingError is present only for wrapping cases")
    func videoErrorUnderlyingError() {
        #expect(VideoError.processingFailed(sampleURL, underlying).underlyingError != nil)
        #expect(VideoError.metadataExtractionFailed(sampleURL, underlying).underlyingError != nil)
        #expect(VideoError.thumbnailGenerationFailed(sampleURL, underlying).underlyingError != nil)

        #expect(VideoError.fileNotFound(sampleURL).underlyingError == nil)
        #expect(VideoError.accessDenied(sampleURL).underlyingError == nil)
        #expect(VideoError.cancelled.underlyingError               == nil)
    }

    @Test("VideoError.associatedURL is populated where documented")
    func videoErrorAssociatedURL() {
        #expect(VideoError.fileNotFound(sampleURL).associatedURL == sampleURL)
        #expect(VideoError.videoTrackNotFound(sampleURL).associatedURL == sampleURL)
        #expect(VideoError.metadataExtractionFailed(sampleURL, underlying).associatedURL == sampleURL)
        #expect(VideoError.processingFailed(sampleURL, underlying).associatedURL == sampleURL)
        #expect(VideoError.thumbnailGenerationFailed(sampleURL, underlying).associatedURL == sampleURL)
        #expect(VideoError.cancelled.associatedURL == nil)
    }

    // MARK: - PreviewError

    @Test("PreviewError.errorDescription is non-nil and non-empty for every case")
    func previewErrorDescriptions() {
        let errors: [PreviewError] = [
            .invalidConfiguration("bad setting"),
            .videoLoadFailed(sampleURL, underlying),
            .extractionFailed("seg 3", nil),
            .extractionFailed("seg 3", underlying),
            .compositionFailed("track mix", nil),
            .compositionFailed("track mix", underlying),
            .encodingFailed("codec", nil),
            .encodingFailed("codec", underlying),
            .saveFailed(sampleURL, underlying),
            .audioProcessingFailed(underlying),
            .cancelled,
            .insufficientVideoDuration(required: 60, actual: 10),
            .noVideoTracks,
            .outputDirectoryCreationFailed(sampleURL, underlying),
            .exportStalled(elapsedSeconds: 30)
        ]
        for error in errors {
            let desc = error.errorDescription
            #expect(desc != nil,    "\(error): errorDescription is nil")
            #expect(!desc!.isEmpty, "\(error): errorDescription is empty")
        }
    }

    @Test("PreviewError.failureReason is non-nil for every case")
    func previewErrorFailureReasons() {
        let errors: [PreviewError] = [
            .invalidConfiguration("x"), .videoLoadFailed(sampleURL, underlying),
            .extractionFailed("x", nil), .compositionFailed("x", nil),
            .encodingFailed("x", nil), .saveFailed(sampleURL, underlying),
            .audioProcessingFailed(underlying), .cancelled, .noVideoTracks,
            .insufficientVideoDuration(required: 60, actual: 10),
            .outputDirectoryCreationFailed(sampleURL, underlying),
            .exportStalled(elapsedSeconds: 30)
        ]
        for error in errors {
            #expect(error.failureReason != nil, "\(error): failureReason is nil")
        }
    }

    @Test("PreviewError.recoverySuggestion is non-nil for all non-cancelled cases")
    func previewErrorRecoverySuggestions() {
        let errors: [PreviewError] = [
            .invalidConfiguration("x"), .videoLoadFailed(sampleURL, underlying),
            .extractionFailed("x", nil), .compositionFailed("x", nil),
            .encodingFailed("x", nil), .saveFailed(sampleURL, underlying),
            .audioProcessingFailed(underlying), .noVideoTracks,
            .insufficientVideoDuration(required: 60, actual: 10),
            .outputDirectoryCreationFailed(sampleURL, underlying),
            .exportStalled(elapsedSeconds: 30)
        ]
        for error in errors {
            #expect(error.recoverySuggestion != nil, "\(error): recoverySuggestion is nil")
        }
        // .cancelled is the one case with nil recovery suggestion
        #expect(PreviewError.cancelled.recoverySuggestion == nil)
    }

    @Test("PreviewError.insufficientVideoDuration embeds both durations in errorDescription")
    func previewErrorInsufficientDuration() {
        let error = PreviewError.insufficientVideoDuration(required: 60, actual: 10)
        #expect(error.errorDescription!.contains("60"))
        #expect(error.errorDescription!.contains("10"))
    }

    @Test("PreviewError.insufficientVideoDuration recoverySuggestion mentions the required threshold")
    func previewErrorInsufficientDurationSuggestion() {
        let error = PreviewError.insufficientVideoDuration(required: 90, actual: 5)
        #expect(error.recoverySuggestion!.contains("90"))
    }

    @Test("PreviewError.exportStalled embeds elapsed seconds in errorDescription")
    func previewErrorExportStalledDescription() {
        let error = PreviewError.exportStalled(elapsedSeconds: 120)
        #expect(error.errorDescription!.contains("120"))
    }

    @Test("PreviewError.extractionFailed without underlying error still has description")
    func previewErrorExtractionNoUnderlying() {
        let error = PreviewError.extractionFailed("segment 7", nil)
        let desc  = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains("segment 7"))
    }

    @Test("PreviewError.extractionFailed with underlying error includes its description")
    func previewErrorExtractionWithUnderlying() {
        let error = PreviewError.extractionFailed("segment 7", underlying)
        let desc  = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains("segment 7"))
        #expect(desc!.contains("underlying test error"))
    }
}
