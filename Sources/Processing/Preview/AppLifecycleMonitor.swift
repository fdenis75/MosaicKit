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
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
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
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }
    }
    
    /// Suspends the current task until the app returns to the foreground.
    /// If the app is already in the foreground, returns immediately.
    public func waitUntilForeground() async {
        if !isInBackground { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
