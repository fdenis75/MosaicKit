//
//  PreviewGenerationProgress.swift
//  MosaicKit
//
//  Created by Claude Code on 2025-11-23.
//

@preconcurrency import Foundation
@preconcurrency import AVFoundation

/// Status of preview video generation
@available(macOS 26, iOS 26, *)
public enum PreviewGenerationStatus: String, Codable, Sendable {
    case queued
    case analyzing
    case extracting
    case composing
    case encoding
    case saving
    case completed
    case failed
    case cancelled

    /// Display label for UI
    public var displayLabel: String {
        switch self {
        case .queued:
            return "Queued"
        case .analyzing:
            return "Analyzing video..."
        case .extracting:
            return "Extracting segments..."
        case .composing:
            return "Composing preview..."
        case .encoding:
            return "Encoding video..."
        case .saving:
            return "Saving..."
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Whether generation is still in progress
    public var isActive: Bool {
        switch self {
        case .queued, .analyzing, .extracting, .composing, .encoding, .saving:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

/// Progress information for preview video generation
@available(macOS 26, iOS 26, *)
public struct PreviewGenerationProgress: Sendable {
    /// The video being processed
    public let video: VideoInput

    /// Current progress (0.0 - 1.0)
    public let progress: Double

    /// Current status
    public let status: PreviewGenerationStatus

    /// Output URL (available when completed)
    public let outputURL: URL?

    /// Error information (if failed)
    public let error: Error?

    /// Additional status message
    public let message: String?

    public init(
        video: VideoInput,
        progress: Double,
        status: PreviewGenerationStatus,
        outputURL: URL? = nil,
        error: Error? = nil,
        message: String? = nil
    ) {
        self.video = video
        self.progress = progress
        self.status = status
        self.outputURL = outputURL
        self.error = error
        self.message = message
    }

    /// Create a queued progress
    public static func queued(for video: VideoInput) -> PreviewGenerationProgress {
        PreviewGenerationProgress(
            video: video,
            progress: 0.0,
            status: .queued
        )
    }

    /// Create a completed progress
    public static func completed(for video: VideoInput, outputURL: URL) -> PreviewGenerationProgress {
        PreviewGenerationProgress(
            video: video,
            progress: 1.0,
            status: .completed,
            outputURL: outputURL
        )
    }

    /// Create a failed progress
    public static func failed(for video: VideoInput, error: Error) -> PreviewGenerationProgress {
        PreviewGenerationProgress(
            video: video,
            progress: 0.0,
            status: .failed,
            error: error
        )
    }

    /// Create a cancelled progress
    public static func cancelled(for video: VideoInput) -> PreviewGenerationProgress {
        PreviewGenerationProgress(
            video: video,
            progress: 0.0,
            status: .cancelled
        )
    }
}

/// Result of preview video generation
@available(macOS 26, iOS 26, *)
public struct PreviewGenerationResult: Sendable {
    /// The video that was processed
    public let video: VideoInput

    /// Output URL if successful
    public let outputURL: URL?

    /// Error if generation failed
    public let error: Error?

    /// Whether generation was successful
    public var isSuccess: Bool {
        return outputURL != nil && error == nil
    }

    public init(video: VideoInput, outputURL: URL?, error: Error?) {
        self.video = video
        self.outputURL = outputURL
        self.error = error
    }

    /// Create a successful result
    public static func success(video: VideoInput, outputURL: URL) -> PreviewGenerationResult {
        PreviewGenerationResult(video: video, outputURL: outputURL, error: nil)
    }

    /// Create a failed result
    public static func failure(video: VideoInput, error: Error) -> PreviewGenerationResult {
        PreviewGenerationResult(video: video, outputURL: nil, error: error)
    }
}

/// Result of preview composition generation (for video player playback)
@available(macOS 26, iOS 26, *)
public struct PreviewCompositionResult: Sendable {
    /// The video that was processed
    public let video: VideoInput

    /// AVPlayerItem if successful
    public let playerItem: AVPlayerItem?

    /// Error if generation failed
    public let error: Error?

    /// Whether generation was successful
    public var isSuccess: Bool {
        return playerItem != nil && error == nil
    }

    public init(video: VideoInput, playerItem: AVPlayerItem?, error: Error?) {
        self.video = video
        self.playerItem = playerItem
        self.error = error
    }

    /// Create a successful result
    public static func success(video: VideoInput, playerItem: AVPlayerItem) -> PreviewCompositionResult {
        PreviewCompositionResult(video: video, playerItem: playerItem, error: nil)
    }

    /// Create a failed result
    public static func failure(video: VideoInput, error: Error) -> PreviewCompositionResult {
        PreviewCompositionResult(video: video, playerItem: nil, error: error)
    }
}
