import Foundation
import AVFoundation
import CoreGraphics

/// Errors that can occur during mosaic generation.
public enum MosaicError: LocalizedError {
    /// Failed to create the mosaic layout.
    case layoutCreationFailed(Error)
    /// Failed to generate the mosaic image.
    case imageGenerationFailed(Error)
    /// Failed to save the mosaic image.
    case saveFailed(URL, Error)
    /// The mosaic dimensions are invalid.
    case invalidDimensions(CGSize)
    /// The mosaic configuration is invalid.
    case invalidConfiguration(String)
    /// A general error occurred during mosaic generation.
    case generationFailed(Error)
    /// The file already exists at the specified location.
    case fileExists(URL)
    case contextCreationFailed
    case imageCreationFailed
    case invalidVideo(String)
    case metalNotSupported
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .layoutCreationFailed(let error):
            return "Failed to create mosaic layout: \(error.localizedDescription)"
        case .imageGenerationFailed(let error):
            return "Failed to generate mosaic image: \(error.localizedDescription)"
        case .saveFailed(let url, let error):
            return "Failed to save mosaic image at \(url.path): \(error.localizedDescription)"
        case .invalidDimensions(let size):
            return "Invalid mosaic dimensions: \(size)"
        case .invalidConfiguration(let message):
            return "Invalid mosaic configuration: \(message)"
        case .generationFailed(let error):
            return "Mosaic generation failed: \(error.localizedDescription)"
        case .fileExists(let url):
            return "File already exists at \(url.path)"
        case .contextCreationFailed:
            return "Failed to create graphics context"
        case .imageCreationFailed:
            return "Failed to create image"
        case .invalidVideo(let message):
            return "Invalid video: \(message)"
        case .metalNotSupported:
            return "Metal is not supported on this device"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        }
    }
}

/// Errors that can occur during library operations.
public enum LibraryError: LocalizedError {
    /// Failed to create a library item.
    case itemCreationFailed(String)
    /// Failed to delete a library item.
    case itemDeletionFailed(String)
    /// Failed to move a library item.
    case itemMoveFailed(String)
    /// Failed to update a library item.
    case itemUpdateFailed(String)
    /// The library item was not found.
    case itemNotFound(String)
    /// The library operation is not supported.
    case operationNotSupported(String)
    /// A general error occurred during library operations.
    case operationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .itemCreationFailed(let message):
            return "Failed to create library item: \(message)"
        case .itemDeletionFailed(let message):
            return "Failed to delete library item: \(message)"
        case .itemMoveFailed(let message):
            return "Failed to move library item: \(message)"
        case .itemUpdateFailed(let message):
            return "Failed to update library item: \(message)"
        case .itemNotFound(let message):
            return "Library item not found: \(message)"
        case .operationNotSupported(let message):
            return "Library operation not supported: \(message)"
        case .operationFailed(let message):
            return "Library operation failed: \(message)"
        }
    }
}
