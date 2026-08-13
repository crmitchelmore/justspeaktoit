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
    private var recordingStartedAt: Date?
    private var recordingError: String?
    private var latestCaptureStatus: WatchCaptureStatus?
    private var latestCaptureAt: Date?
    private var latestFailureMessage: String?
    private var inFlightCount = 0
    private var published: WatchComplicationSnapshot?
    private var heartbeat: Task<Void, Never>?

    private init() {}

    func update(isRecording: Bool, recordingStartedAt: Date?) {
        self.isRecording = isRecording
        self.recordingStartedAt = recordingStartedAt
        self.publish()
    }

    func update(recordingError: String?) {
        self.recordingError = recordingError
        self.publish()
    }

    func update(captures: [WatchCapture]) {
        let latest = captures.first
        self.latestCaptureStatus = latest?.status
        self.latestCaptureAt = latest?.createdAt
        self.latestFailureMessage = latest?.status == .failed ? latest?.message : nil
        // Count every status the face calls "sending", so the Smart Stack
        // headline and its subtitle agree.
        self.inFlightCount = captures.filter { !$0.status.isTerminal && $0.status != .failed }.count
        self.publish()
    }

    private func snapshot() -> WatchComplicationSnapshot {
        let now = Date()
        let state = if !self.isRecording, self.recordingError != nil {
            WatchComplicationState.failed
        } else {
            WatchComplicationState.state(
                isRecording: self.isRecording,
                latestCaptureStatus: self.latestCaptureStatus
            )
        }
        return WatchComplicationSnapshot(
            state: state,
            updatedAt: now,
            recordingStartedAt: self.recordingStartedAt,
            latestCaptureAt: self.latestCaptureAt,
            latestCaptureStatus: self.latestCaptureStatus,
            failureMessage: self.recordingError ?? self.latestFailureMessage,
            expiresAt: state == .recording
                ? now.addingTimeInterval(WatchComplicationSnapshot.recordingStaleAfter)
                : nil,
            inFlightCount: self.inFlightCount
        )
    }

    private func publish() {
        let snapshot = self.snapshot()
        // `updatedAt` always differs, so compare the parts a face renders and
        // skip the write plus the reload when nothing visible changed. A
        // recording always writes: its timestamp is the proof that the
        // recording continues.
        let isRecordingState = snapshot.state == .recording
        if !isRecordingState, let published, published.rendersIdentically(to: snapshot) {
            return
        }
        self.published = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
        self.syncHeartbeat(isRecording: isRecordingState)
    }

    /// Refreshes the timestamp while the app records, so a face can tell a
    /// live recording from one that a stopped app left behind. The heartbeat
    /// writes only: it must not spend the widget reload budget every 30
    /// seconds, and the widget reads the file on its own refresh.
    private func syncHeartbeat(isRecording: Bool) {
        guard isRecording else {
            self.heartbeat?.cancel()
            self.heartbeat = nil
            return
        }
        guard self.heartbeat == nil else { return }
        self.heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WatchComplicationSnapshot.recordingHeartbeat))
                guard let self, !Task.isCancelled, self.isRecording else { return }
                self.snapshot().save()
            }
        }
    }
}

private extension WatchComplicationSnapshot {
    func rendersIdentically(to other: WatchComplicationSnapshot) -> Bool {
        state == other.state
            && recordingStartedAt == other.recordingStartedAt
            && latestCaptureAt == other.latestCaptureAt
            && latestCaptureStatus == other.latestCaptureStatus
            && failureMessage == other.failureMessage
            && inFlightCount == other.inFlightCount
    }
}
