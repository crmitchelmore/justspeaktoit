import Foundation

/// A per-capture notification subscription. Retirement invalidates already queued
/// callbacks as well as removing the token; a replacement capture owns a new ID.
@MainActor
public final class CaptureDisruptionObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private var captureID: UUID?

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    public func observe(
        _ name: Notification.Name,
        object: AnyObject,
        isUsable: @escaping @MainActor () -> Bool,
        onDisruption: @escaping @MainActor () -> Void
    ) {
        observe(name, object: object, matches: { _ in true }, isUsable: isUsable, onDisruption: onDisruption)
    }

    /// Filter the event before hopping to the owner, retaining this capture's identity.
    public func observe(
        _ name: Notification.Name,
        object: AnyObject?,
        matches: @escaping @Sendable (Notification) -> Bool,
        isUsable: @escaping @MainActor () -> Bool,
        onDisruption: @escaping @MainActor () -> Void
    ) {
        stop()
        let id = UUID()
        captureID = id
        token = center.addObserver(forName: name, object: object, queue: nil) { [weak self] notification in
            guard matches(notification) else { return }
            // AVAudioEngine posts on its internal queue. Never stop or release
            // the engine there, and recheck capture ownership after the hop.
            Task { @MainActor [weak self] in
                guard let self, self.captureID == id, !isUsable() else { return }
                self.stop()
                onDisruption()
            }
        }
    }

    public func stop() {
        captureID = nil
        if let token { center.removeObserver(token) }
        token = nil
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
