import Foundation

/// The ffmpeg job writing each cache file, so concurrent readers share one ffmpeg run.
///
/// Each reader is a waiter. A cancelled waiter stops waiting at once with `CancellationError`;
/// ffmpeg is stopped only when the last waiter leaves, so cancelling one job (say a preview)
/// doesn't fail another job reading the same source (a mosaic).
actor RemuxJobs {
    static let shared = RemuxJobs()

    private struct Job {
        /// A cancelled job's late completion must not touch the job that replaced it.
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
    }
    private var jobs: [URL: Job] = [:]
    /// Waiters cancelled before they joined (the cancel handler can run first).
    private var cancelledBeforeJoining: Set<UUID> = []

    /// The remuxed file of `source`, from the running remux or a new one made by `work`.
    nonisolated func result(for source: URL, _ work: @escaping @Sendable () async throws -> URL) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.join(source, id: id, continuation: continuation, work: work) }
            }
        } onCancel: {
            Task { await self.leave(source, id: id) }
        }
    }

    private func join(_ source: URL, id: UUID, continuation: CheckedContinuation<URL, any Error>,
                      work: @escaping @Sendable () async throws -> URL) {
        if cancelledBeforeJoining.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        if jobs[source] == nil {
            let token = UUID()
            let task = Task {
                let outcome: Result<URL, any Error>
                do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
                self.complete(source, token: token, with: outcome)
            }
            jobs[source] = Job(token: token, task: task)
        }
        jobs[source]?.waiters[id] = continuation
    }

    private func leave(_ source: URL, id: UUID) {
        guard var job = jobs[source], let continuation = job.waiters.removeValue(forKey: id) else {
            cancelledBeforeJoining.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.task.cancel()
            jobs[source] = nil   // a later reader starts a new remux instead of joining a cancelled one
        } else {
            jobs[source] = job
        }
    }

    private func complete(_ source: URL, token: UUID, with outcome: Result<URL, any Error>) {
        guard let job = jobs[source], job.token == token else { return }
        jobs[source] = nil
        for continuation in job.waiters.values { continuation.resume(with: outcome) }
    }
}
