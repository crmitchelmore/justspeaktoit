#if os(iOS)
import Foundation
import UIKit

/// Flushes History when the app leaves the foreground or terminates, and
/// retries storage once protected data becomes readable again. Owns the
/// observer tokens, so they are removed when History is released.
@MainActor
final class IOSHistoryLifecycleObservers {
    private var tokens: [NSObjectProtocol] = []

    /// Observers are delivered on the main queue, so each block runs on the main actor.
    init(history: iOSHistoryManager) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak history] _ in
            MainActor.assumeIsolated {
                guard let history else { return }
                let assertion = BackgroundTaskAssertion(name: "History flush")
                Task { await history.flushPendingChangesAndWait(); assertion.end() }
            }
        })
        tokens.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak history] _ in
            // Termination provides no guaranteed asynchronous execution window.
            MainActor.assumeIsolated { history?.flushPendingChanges() }
        })
        tokens.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak history] _ in
            MainActor.assumeIsolated {
                _ = Task { await history?.retryPersistenceAndWait() }
            }
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
#endif
