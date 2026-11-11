#if os(iOS)
import SpeakCore
import UIKit

extension TranscriptionResult {
    /// Returns a copy with `text` replaced, preserving all other metadata. Used
    /// so the returned result, history entry, clipboard, and spoken dialog all
    /// agree on the same best-available transcript.
    func replacingText(_ newText: String) -> TranscriptionResult {
        TranscriptionResult(
            text: newText,
            segments: segments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: modelIdentifier,
            cost: cost,
            rawPayload: rawPayload,
            debugInfo: debugInfo
        )
    }
}

/// Reference-type wrapper around a UIKit background-task assertion that
/// guarantees `endBackgroundTask` is called exactly once — whether via the
/// normal completion path or the system expiration handler — avoiding the
/// double-end API violation.
@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false
    private var expired = false
    private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
    var isValid: Bool { !ended && identifier != .invalid }
    var onExpiration: (() -> Void)? {
        didSet {
            if expired { onExpiration?() }
        }
    }

    init(
        name: String,
        begin: @MainActor (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: $0, expirationHandler: $1)
        },
        end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        endTask = end
        let allocated = begin(name) { [weak self] in
            guard let self else { return }
            self.expired = true
            self.onExpiration?()
            self.end()
        }
        // Expiration can arrive before begin returns its identifier.
        if ended {
            if allocated != .invalid { endTask(allocated) }
        } else {
            identifier = allocated
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        onExpiration = nil
        if identifier != .invalid { endTask(identifier) }
        identifier = .invalid
    }
}
#endif
