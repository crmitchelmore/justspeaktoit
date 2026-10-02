import Foundation

/// Owns Copy submissions separately from selection and version changes. Text is
/// already captured from the display; the eventual writer never rereads History.
/// One worker and one latest pending snapshot keep the final clipboard current.
public final class DesktopTranscriptCopyDispatcher: Sendable {
    typealias Launcher = @Sendable (@escaping @Sendable () async -> Void) -> Void
    private struct Snapshot: Sendable {
        let text: String
        let variant: DesktopTranscriptVariant?
    }
    private let events: DesktopEventDispatcher<Snapshot>

    public convenience init(copy: @escaping @Sendable (String, DesktopTranscriptVariant?) async -> Void) {
        self.init(launch: { operation in Task { await operation() } }, copy: copy)
    }

    init(launch: @escaping Launcher, copy: @escaping @Sendable (String, DesktopTranscriptVariant?) async -> Void) {
        self.events = DesktopEventDispatcher(launch: launch) { snapshot in
            await copy(snapshot.text, snapshot.variant)
        }
    }

    public func submit(_ text: String, variant: DesktopTranscriptVariant?) {
        events.submit(Snapshot(text: text, variant: variant))
    }
}
