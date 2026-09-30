import Foundation
import Darwin

/// Background scheduling of the test process (I-26).
///
/// macOS can run a process under background scheduling (`PRIO_DARWIN_BG`: throttled CPU and
/// I/O, the policy `taskpolicy -b` applies) or with a background QoS clamp (`taskpolicy -c
/// background`). Under either, `AVAssetExportSession` can stall mid-encode for minutes. The
/// first can be left (`leaveBackground()`); a clamp cannot, so `diagnostics()` reports it.
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

    /// A one-line description of the scheduling facts that affect exports, for test logs:
    /// darwin background scheduling, the main thread's QoS (which shows a QoS clamp such as
    /// `taskpolicy -c background` applied at launch, 0x9; normal is 0x21), whether the machine is
    /// a virtual machine, and its thermal state. A process cannot lift a QoS clamp itself.
    static func diagnostics() async -> String {
        let mainQoS = await MainActor.run { qos_class_self().rawValue }
        return "darwinBackground=\(isBackground) mainThreadQoS=0x\(String(mainQoS, radix: 16)) "
            + "virtualMachine=\(isVirtualMachine) thermalState=\(ProcessInfo.processInfo.thermalState.rawValue)"
    }

    /// Whether the process runs in a virtual machine (`kern.hv_vmm_present`), as on GitHub's
    /// macOS runners.
    static var isVirtualMachine: Bool {
        var vmm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &vmm, &size, nil, 0) == 0 && vmm == 1
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
