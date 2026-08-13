import Foundation
import WidgetKit

/// Mirrors the two pieces of state a watch face cares about — is a recording
/// in progress, and what happened to the newest capture — into the App Group
/// container, then asks WidgetKit to redraw.
///
/// The recorder and the capture store each push the half they own; this type
/// composes them so neither has to know about the other or about WidgetKit.
@MainActor
final class WatchComplicationPublisher {
    static let shared = WatchComplicationPublisher()

    private var isRecording = false
    private var latestCaptureStatus: WatchCaptureStatus?
    private var latestCaptureAt: Date?
    private var pendingCount = 0
    private var published: WatchComplicationSnapshot?

    private init() {}

    func update(isRecording: Bool) {
        self.isRecording = isRecording
        self.publish()
    }

    func update(captures: [WatchCapture]) {
        let latest = captures.first
        self.latestCaptureStatus = latest?.status
        self.latestCaptureAt = latest?.createdAt
        self.pendingCount = captures.filter { $0.status == .recorded || $0.status == .transferring }.count
        self.publish()
    }

    private func publish() {
        let snapshot = WatchComplicationSnapshot(
            state: .state(isRecording: self.isRecording, latestCaptureStatus: self.latestCaptureStatus),
            latestCaptureAt: self.latestCaptureAt,
            pendingCount: self.pendingCount
        )
        // `updatedAt` always differs, so compare the parts a face renders and
        // skip the write plus the reload when nothing visible changed.
        if let published, published.rendersIdentically(to: snapshot) { return }
        self.published = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private extension WatchComplicationSnapshot {
    func rendersIdentically(to other: WatchComplicationSnapshot) -> Bool {
        state == other.state
            && latestCaptureAt == other.latestCaptureAt
            && pendingCount == other.pendingCount
    }
}
