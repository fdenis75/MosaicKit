import Foundation
#if os(macOS)
import Darwin
#endif

/// Background scheduling of the test process (I-26).
///
/// macOS can run a process under background scheduling (`PRIO_DARWIN_BG`: throttled CPU and
/// I/O, the policy `taskpolicy -b` applies). Under it, `AVAssetExportSession` stalls mid-encode
/// for minutes, which is what made `PreviewExportSmokeTests` fail intermittently on CI.
enum ProcessScheduling {

    /// Whether the process currently runs under darwin background scheduling. Always `false`
    /// off macOS.
    static var isBackground: Bool {
        #if os(macOS)
        return getpriority(PRIO_DARWIN_PROCESS, 0) != 0
        #else
        return false
        #endif
    }

    /// Moves the process out of darwin background scheduling (like `taskpolicy -B`) and
    /// returns whether it was in it. A no-op returning `false` off macOS.
    ///
    /// Test-only: the library never changes its host's scheduling.
    @discardableResult
    static func leaveBackground() -> Bool {
        #if os(macOS)
        guard isBackground else { return false }
        _ = setpriority(PRIO_DARWIN_PROCESS, 0, 0)
        return true
        #else
        return false
        #endif
    }
}
