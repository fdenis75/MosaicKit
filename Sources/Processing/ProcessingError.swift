import Foundation
import AVFoundation
import CoreGraphics

/// An enumeration representing errors that can occur during video mosaic generation.
public enum MosaicError: LocalizedError {
    /// The layout creation failed.
    case layoutCreationFailed(Error)
    /// The mosaic image rendering failed.
    case imageGenerationFailed(Error)
    /// Saving the generated mosaic file failed.
    case saveFailed(URL, Error)
    /// The mosaic target dimensions are invalid.
    case invalidDimensions(CGSize)
    /// The configuration parameters are invalid.
    case invalidConfiguration(String)
    /// A general error occurred during mosaic generation.
    case generationFailed(Error)
    /// A file already exists at the output destination URL.
    case fileExists(URL)
    /// Creating the Core Graphics or Core Image context failed.
    case contextCreationFailed
    /// Creating the final image destination failed.
    case imageCreationFailed
    /// The video file is invalid or cannot be read.
    case invalidVideo(String)
    /// Metal hardware acceleration is not supported on this device.
    case metalNotSupported
    /// Core image processing operation failed.
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
