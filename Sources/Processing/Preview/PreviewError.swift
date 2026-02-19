import Foundation

/// Errors that can occur during preview video generation
@available(macOS 26, iOS 26, *)
public enum PreviewError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case videoLoadFailed(URL, Error)
    case extractionFailed(String, Error?)
    case compositionFailed(String, Error?)
    case encodingFailed(String, Error?)
    case saveFailed(URL, Error)
    case audioProcessingFailed(Error)
    case cancelled
    case insufficientVideoDuration(required: TimeInterval, actual: TimeInterval)
    case noVideoTracks
    case outputDirectoryCreationFailed(URL, Error)
    case exportStalled(elapsedSeconds: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .videoLoadFailed(let url, let error):
            return "Failed to load video at \(url.lastPathComponent): \(error.localizedDescription)"
        case .extractionFailed(let message, let error):
            if let error = error {
                return "Extraction failed: \(message) - \(error.localizedDescription)"
            } else {
                return "Extraction failed: \(message)"
            }
        case .compositionFailed(let message, let error):
            if let error = error {
                return "Composition failed: \(message) - \(error.localizedDescription)"
            } else {
                return "Composition failed: \(message)"
            }
        case .encodingFailed(let message, let error):
            if let error = error {
                return "Encoding failed: \(message) - \(error.localizedDescription)"
            } else {
                return "Encoding failed: \(message)"
            }
        case .saveFailed(let url, let error):
            return "Failed to save to \(url.lastPathComponent): \(error.localizedDescription)"
        case .audioProcessingFailed(let error):
            return "Audio processing failed: \(error.localizedDescription)"
        case .cancelled:
            return "Preview generation was cancelled"
        case .insufficientVideoDuration(let required, let actual):
            return "Video too short: requires at least \(Int(required))s, but video is only \(Int(actual))s"
        case .noVideoTracks:
            return "Video file contains no video tracks"
        case .outputDirectoryCreationFailed(let url, let error):
            return "Failed to create output directory at \(url.path): \(error.localizedDescription)"
        case .exportStalled(let elapsed):
            return "Export stalled: no progress for \(elapsed) seconds"
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidConfiguration:
            return "The preview configuration contains invalid parameters"
        case .videoLoadFailed:
            return "The video file could not be loaded or is corrupted"
        case .extractionFailed:
            return "Failed to extract video segments"
        case .compositionFailed:
            return "Failed to compose video segments"
        case .encodingFailed:
            return "Failed to encode the final video"
        case .saveFailed:
            return "Failed to save the output file"
        case .audioProcessingFailed:
            return "Failed to process audio tracks"
        case .cancelled:
            return "User cancelled the operation"
        case .insufficientVideoDuration:
            return "Source video is too short for the requested preview configuration"
        case .noVideoTracks:
            return "The file does not contain valid video data"
        case .outputDirectoryCreationFailed:
            return "Could not create the output directory"
        case .exportStalled:
            return "The export encoder stopped making progress"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidConfiguration:
            return "Check the preview duration, density, and other settings"
        case .videoLoadFailed:
            return "Verify the video file exists and is in a supported format"
        case .extractionFailed, .compositionFailed:
            return "Try using a lower density or shorter duration"
        case .encodingFailed:
            return "Try using a different format or lower quality setting"
        case .saveFailed:
            return "Check that you have write permissions for the output directory"
        case .audioProcessingFailed:
            return "Try generating the preview without audio"
        case .cancelled:
            return nil
        case .insufficientVideoDuration(let required, _):
            return "Use a shorter preview duration (less than \(Int(required))s) or lower density"
        case .noVideoTracks:
            return "Verify the file is a valid video file"
        case .outputDirectoryCreationFailed:
            return "Check disk space and permissions"
        case .exportStalled:
            return "Try a different export preset, lower quality, or a different format"
        }
    }
}
