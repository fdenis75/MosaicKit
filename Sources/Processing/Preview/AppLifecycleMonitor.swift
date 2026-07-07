import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Monitors app lifecycle events across macOS and iOS
public actor AppLifecycleMonitor {
    public static let shared = AppLifecycleMonitor()
    
    public private(set) var isInBackground: Bool = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    
    private init() {
        Task {
            await startMonitoring()
        }
    }
    
    private func startMonitoring() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.setBackgroundState(true) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.setBackgroundState(false) }
        }
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.setBackgroundState(true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.setBackgroundState(false) }
        }
        #endif
    }
    
    private func setBackgroundState(_ isBackground: Bool) {
        self.isInBackground = isBackground
        if !isBackground {
            // Resume all waiters
            for waiter in waiters.values {
                waiter.resume()
            }
            waiters.removeAll()
        }
    }

    /// Suspends the current task until the app returns to the foreground.
    /// If the app is already in the foreground, returns immediately.
    ///
    /// Cancellation-aware: if the waiting task is cancelled, the wait resumes
    /// immediately instead of holding the (cancelled) work hostage until the app
    /// is foregrounded. Callers that care should check `Task.isCancelled` after
    /// this returns.
    public func waitUntilForeground() async {
        if !isInBackground { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Both checks and the insertion run in one actor-isolated critical
                // section, so the onCancel resume below cannot interleave here.
                if !isInBackground || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }
}
