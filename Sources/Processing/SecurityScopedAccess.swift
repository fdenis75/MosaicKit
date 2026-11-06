import Foundation

/// A held security-scoped grant for an output location (sandboxed macOS apps).
///
/// `startAccessingSecurityScopedResource()` returns `false` for a URL that does not exist yet,
/// which is the normal state of a generated output directory (`{root}/{service}/{hash}/`) and of
/// a staging file. The grant that matters is the one on the nearest existing ancestor, usually the
/// folder the user picked, so `begin(for:)` walks up from the URL until a call succeeds. A `false`
/// result everywhere is not an error: the URL is simply not security-scoped (no sandbox, temp
/// directory, CLI use), and access is governed by ordinary file permissions.
///
/// Every successful start is balanced by exactly one stop, on `stop()` or at deinit.
internal final class SecurityScopedAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: URL?

    private init(granted: URL?) { self.granted = granted }

    /// Starts access for `url`, or for its nearest ancestor that grants it.
    internal static func begin(for url: URL) -> SecurityScopedAccess {
        var candidate = url
        // Bounded walk: stop at the filesystem root or when the path stops shrinking.
        for _ in 0..<64 {
            if candidate.startAccessingSecurityScopedResource() {
                return SecurityScopedAccess(granted: candidate)
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || parent.path.isEmpty || parent.path == "/" { break }
            candidate = parent
        }
        return SecurityScopedAccess(granted: nil)
    }

    /// Runs `body` while access to `url` is held.
    internal static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let access = begin(for: url)
        defer { access.stop() }
        return try body()
    }

    /// Releases the grant. Safe to call more than once.
    internal func stop() {
        lock.lock()
        let url = granted
        granted = nil
        lock.unlock()
        url?.stopAccessingSecurityScopedResource()
    }

    deinit { stop() }
}
