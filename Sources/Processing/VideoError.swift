import Foundation

/// Errors related to video processing and metadata extraction.
@available(macOS 15, iOS 18, *)
public enum VideoError: Error, LocalizedError, Equatable {
    /// The video track could not be found in the asset.
    case videoTrackNotFound(URL)
    
    /// The video file could not be found at the specified URL.
    case fileNotFound(URL)
    
    /// The video file could not be accessed due to permissions.
    case accessDenied(URL)
    
    /// The video file is corrupted or in an unsupported format.
    case invalidFormat(URL)
    
    /// The video processing operation failed.
    case processingFailed(URL, Error)
    
    /// The video metadata extraction failed.
    case metadataExtractionFailed(URL, Error)
    
    /// The video thumbnail generation failed.
    case thumbnailGenerationFailed(URL, Error)
    
    /// The video frame extraction failed.
    case frameExtractionFailed(URL, Error)
    
    case cancelled
    
    /// Provides a user-friendly description for the error.
    public var errorDescription: String? {
        switch self {
        case .videoTrackNotFound(let url):
            return "No video track found in file: \(url.lastPathComponent)"
        case .fileNotFound(let url):
            return "Video file not found at path: \(url.path)"
        case .accessDenied(let url):
            return "Access denied to video file at \(url.path)"
        case .invalidFormat(let url):
            return "Invalid or unsupported video format at \(url.path)"
        case .processingFailed(let url, let error):
            return "Processing failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .metadataExtractionFailed(let url, let error):
            return "Failed to extract metadata for \(url.lastPathComponent): \(error.localizedDescription)"
        case .thumbnailGenerationFailed(let url, let error):
            return "Failed to generate thumbnail for \(url.lastPathComponent): \(error.localizedDescription)"
        case .frameExtractionFailed(let url, let error):
            return "Failed to extract frames from video at \(url.path): \(error.localizedDescription)"
        case .cancelled:
            return "Video processing operation was cancelled."
        }
    }
    
    /// Returns the underlying error, if any.
    public var underlyingError: Error? {
        switch self {
        case .metadataExtractionFailed(_, let error),
             .thumbnailGenerationFailed(_, let error),
             .processingFailed(_, let error):
            return error
        case .fileNotFound, .videoTrackNotFound, .accessDenied, .invalidFormat, .frameExtractionFailed, .cancelled:
            return nil
        }
    }

    /// Returns the associated URL for the error, if available.
    public var associatedURL: URL? {
        switch self {
        case .fileNotFound(let url),
             .metadataExtractionFailed(let url, _),
             .videoTrackNotFound(let url),
             .thumbnailGenerationFailed(let url, _),
             .processingFailed(let url, _):
            return url
        case .accessDenied, .invalidFormat, .frameExtractionFailed, .cancelled:
            return nil
        }
    }

    public var failureReason: String? {
        switch self {
        case .videoTrackNotFound:
            return "The file does not contain a valid video track"
        case .fileNotFound:
            return "The specified file does not exist"
        case .accessDenied:
            return "The application does not have permission to access the file"
        case .invalidFormat:
            return "The file format is not supported or the file is corrupted"
        case .processingFailed(_, let error):
            return error.localizedDescription
        case .metadataExtractionFailed(_, let error):
            return error.localizedDescription
        case .thumbnailGenerationFailed(_, let error):
            return error.localizedDescription
        case .frameExtractionFailed(_, let error):
            return error.localizedDescription
        case .cancelled:
            return "Processing cancelled"
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .videoTrackNotFound:
            return "Please ensure the file contains valid video content"
        case .fileNotFound:
            return "Please check if the file exists and try again"
        case .accessDenied:
            return "Please grant the application access to the file and try again"
        case .invalidFormat:
            return "Please try with a supported video format"
        case .processingFailed:
            return "Please try again or use a different video file"
        case .metadataExtractionFailed:
            return "Please ensure the video file is not corrupted and try again"
        case .thumbnailGenerationFailed:
            return "Please try again or adjust the thumbnail generation settings"
        case .frameExtractionFailed:
            return "Please try again or adjust the frame extraction settings"
        case .cancelled:
            return "Processing cancelled"
        }
    }

    // MARK: - Equatable Conformance
    // Basic Equatable conformance, may need refinement based on how underlying errors are compared.
    public static func == (lhs: VideoError, rhs: VideoError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound(let lUrl), .fileNotFound(let rUrl)):
            return lUrl == rUrl
        case (.metadataExtractionFailed(let lUrl, _), .metadataExtractionFailed(let rUrl, _)):
             // Comparing underlying errors directly can be tricky. Often comparing URLs is sufficient.
            return lUrl == rUrl
        case (.videoTrackNotFound(let lUrl), .videoTrackNotFound(let rUrl)):
            return lUrl == rUrl
        case (.thumbnailGenerationFailed(let lUrl, _), .thumbnailGenerationFailed(let rUrl, _)):
             // Comparing underlying errors directly can be tricky.
            return lUrl == rUrl
         case (.processingFailed(let lUrl, _), .processingFailed(let rUrl, _)):
             // Comparing underlying errors directly can be tricky.
            return lUrl == rUrl
        case (.cancelled, .cancelled):
            return true
        default:
            return false
        }
    }
} 