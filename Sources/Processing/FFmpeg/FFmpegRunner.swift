#if os(macOS)
import Foundation
import Synchronization

/// One run of `ffmpeg` or `ffprobe`: cancellable, time-limited, with stdin closed (I-32) and
/// output captured in temporary files, so a chatty process can't fill a pipe and stall.
enum FFmpegRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        /// The last 4 KB of stderr.
        let stderr: String
    }

    private struct State {
        var pid: pid_t?
        var cancelled = false
        var timedOut = false
        var status: Int32?
    }

    /// Runs `binary` and waits for it to exit.
    ///
    /// - Throws: `CancellationError` when the task is cancelled (the process is killed),
    ///   ``MosaicError/processingFailed(_:)`` when it runs longer than `timeout`.
    static func run(_ binary: String, _ arguments: [String], timeout: TimeInterval) async throws -> Output {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("mk-ff-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }
        guard fileManager.createFile(atPath: outURL.path, contents: nil),
              fileManager.createFile(atPath: errURL.path, contents: nil) else {
            throw MosaicError.processingFailed("Can't create temporary files for ffmpeg")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }
        process.standardOutput = outHandle
        process.standardError = errHandle

        let state = Mutex(State())
        let kill9: @Sendable (_ timedOut: Bool) -> Void = { timedOut in
            let pid: pid_t? = state.withLock {
                guard $0.status == nil else { return nil }
                if timedOut { $0.timedOut = true } else { $0.cancelled = true }
                return $0.pid
            }
            // SIGKILL: every output goes to a staging or temporary file, so nothing needs a
            // clean ffmpeg shutdown.
            if let pid { kill(pid, SIGKILL) }
        }

        nonisolated(unsafe) let processRef = process
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                // Installed before `run()`: `waitUntilExit()` can miss a short-lived process (I-27).
                processRef.terminationHandler = { finished in
                    state.withLock { $0.status = finished.terminationStatus }
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try processRef.run()
                } catch {
                    processRef.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                let cancelledAlready = state.withLock {
                    $0.pid = processRef.processIdentifier
                    return $0.cancelled
                }
                if cancelledAlready { kill(processRef.processIdentifier, SIGKILL) }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { kill9(true) }
            }
        } onCancel: {
            kill9(false)
        }
        try Task.checkCancellation()
        if state.withLock({ $0.timedOut }) {
            throw MosaicError.processingFailed("ffmpeg did not finish within \(Int(timeout)) s")
        }
        let errorData = (try? Data(contentsOf: errURL)) ?? Data()
        return Output(status: status, stdout: (try? Data(contentsOf: outURL)) ?? Data(),
                      stderr: String(decoding: errorData.suffix(4096), as: UTF8.self))
    }

    /// The input arguments for `url`: only the protocols that source needs, so a crafted file
    /// can't make ffmpeg open other files or addresses.
    static func inputArguments(for url: URL) -> [String] {
        if url.isFileURL {
            return ["-protocol_whitelist", "file", "-i", "file:\(url.path)"]
        }
        return ["-protocol_whitelist", "http,https,tcp,tls,crypto", "-i", url.absoluteString]
    }
}
#endif
