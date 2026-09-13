import Foundation

/// Stable identity for one submitted generation operation.
public struct GenerationJobID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Identity of one execution attempt. A retry always receives a new value.
public struct GenerationAttemptID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum GenerationJobState: String, Codable, Sendable {
    case queued, running, pausing, paused, retryScheduled, cancelling, succeeded, failed, cancelled
}

public struct GenerationJobSnapshot: Codable, Sendable {
    public let id: GenerationJobID
    public let attempt: GenerationAttemptID
    public let state: GenerationJobState
    public let progress: Double
    public let outputURL: URL?
    public let errorDescription: String?
    public init(id: GenerationJobID, attempt: GenerationAttemptID, state: GenerationJobState,
                progress: Double = 0, outputURL: URL? = nil, errorDescription: String? = nil) {
        self.id = id; self.attempt = attempt; self.state = state; self.progress = progress
        self.outputURL = outputURL; self.errorDescription = errorDescription
    }
}

/// A small actor-backed controller for applications that need explicit lifecycle control.
/// Existing generator/coordinator methods remain available and can be adapted to this API.
public actor GenerationJobController {
    public typealias Operation = @Sendable () async throws -> URL
    private struct Record { var snapshot: GenerationJobSnapshot; var task: Task<URL, Error>?; var operation: Operation }
    private var records: [GenerationJobID: Record] = [:]

    public init() {}

    public func submit(operation: @escaping Operation) -> GenerationJobID {
        let id = GenerationJobID()
        let attempt = GenerationAttemptID()
        let initial = GenerationJobSnapshot(id: id, attempt: attempt, state: .queued)
        // Admission is explicit: work does not begin until `value(for:)` is awaited.
        records[id] = Record(snapshot: initial, task: nil, operation: operation)
        return id
    }

    public func snapshot(for id: GenerationJobID) -> GenerationJobSnapshot? { records[id]?.snapshot }

    public func cancel(_ id: GenerationJobID) {
        guard var record = records[id] else { return }
        record.snapshot = GenerationJobSnapshot(id: id, attempt: record.snapshot.attempt, state: .cancelling,
                                                progress: record.snapshot.progress, outputURL: record.snapshot.outputURL)
        record.task?.cancel(); records[id] = record
    }

    /// Cancels queued admission and active work. The operation must itself observe cancellation.
    public func cancelAll() { for id in records.keys { cancel(id) } }

    /// Pausing is a scheduling boundary. Active encoders are allowed to finish; retry resumes work.
    public func pause(_ id: GenerationJobID) {
        guard var record = records[id], record.snapshot.state == .queued else { return }
        record.snapshot = GenerationJobSnapshot(id: id, attempt: record.snapshot.attempt, state: .paused)
        record.task?.cancel(); record.task = nil; records[id] = record
    }

    public func retry(_ id: GenerationJobID) {
        guard var record = records[id], record.snapshot.state == .paused || record.snapshot.state == .failed || record.snapshot.state == .cancelled else { return }
        let attempt = GenerationAttemptID()
        record.snapshot = GenerationJobSnapshot(id: id, attempt: attempt, state: .queued)
        record.task = nil
        records[id] = record
    }

    public func value(for id: GenerationJobID) async throws -> URL {
        guard var record = records[id] else { throw CancellationError() }
        if record.task == nil {
            guard record.snapshot.state == .queued else { throw CancellationError() }
            let operation = record.operation
            record.snapshot = GenerationJobSnapshot(id: id, attempt: record.snapshot.attempt, state: .running)
            record.task = Task { try Task.checkCancellation(); return try await operation() }
            records[id] = record
        }
        guard let task = records[id]?.task else { throw CancellationError() }
        do {
            let url = try await task.value
            if var record = records[id] {
                record.snapshot = GenerationJobSnapshot(id: id, attempt: record.snapshot.attempt, state: .succeeded, progress: 1, outputURL: url)
                records[id] = record
            }
            return url
        } catch is CancellationError {
            if var record = records[id] { record.snapshot = GenerationJobSnapshot(id: id, attempt: record.snapshot.attempt, state: .cancelled); records[id] = record }
            throw CancellationError()
        } catch {
            if var record = records[id] { record.snapshot = GenerationJobSnapshot(id: id, attempt: record.snapshot.attempt, state: .failed, errorDescription: error.localizedDescription); records[id] = record }
            throw error
        }
    }
}
