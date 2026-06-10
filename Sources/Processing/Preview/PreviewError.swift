import Foundation

/// An enumeration representing errors that can occur during preview video generation.
// @available(macOS 26, iOS 26, *)
public enum PreviewError: LocalizedError, Sendable {
    /// The preview configuration parameters are invalid.
    case invalidConfiguration(String)
    /// Loading the video asset failed.
    case videoLoadFailed(URL, Error)
    /// Extracting video clips or frames failed.
    case extractionFailed(String, Error?)
    /// Composing the video segments failed.
    case compositionFailed(String, Error?)
    /// Encoding the composed preview video failed.
    case encodingFailed(String, Error?)
    /// Saving the generated preview file failed.
    case saveFailed(URL, Error)
    /// Processing the audio track failed.
    case audioProcessingFailed(Error)
    /// The preview generation was cancelled.
    case cancelled
    /// The source video's duration is too short to generate a preview.
    case insufficientVideoDuration(required: TimeInterval, actual: TimeInterval)
    /// The video asset has no video tracks.
    case noVideoTracks
    /// Creating the target output directory failed.
    case outputDirectoryCreationFailed(URL, Error)
    /// The export operation stalled without forward progress.
    case exportStalled(elapsedSeconds: Int)
    /// The FFmpeg binary could not be found.
    case ffmpegNotFound(path: String)
    /// The FFmpeg encoding process failed.
    case ffmpegEncodingFailed(exitCode: Int32, output: String)

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
        case .ffmpegNotFound(let path):
            return "FFmpeg binary not found or not executable at: \(path)"
        case .ffmpegEncodingFailed(let code, let output):
            return "FFmpeg exited with code \(code): \(output)"
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
        case .ffmpegNotFound:
            return "The specified FFmpeg binary was not found"
        case .ffmpegEncodingFailed:
            return "FFmpeg failed to encode the video"
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
        case .ffmpegNotFound:
            return "Check that the ffmpeg binary path is correct and the binary is executable"
        case .ffmpegEncodingFailed:
            return "Check the ffmpeg encoding options or try a different codec/quality setting"
        }
    }
}
