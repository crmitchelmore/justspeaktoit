import Foundation
import SpeakWatchCore
import WatchConnectivity

/// Owns the watch-side capture queue: persists capture metadata, hands audio
/// files to WatchConnectivity (whose transfer queue survives the phone being
/// out of range), retains local audio until transcription is acknowledged, and applies
/// transcription acknowledgements coming back from the iPhone.
///
/// The transition rules live in `WatchCaptureQueue` (SpeakWatchCore); this
/// type supplies WatchConnectivity, the persisted file and the complication.
@MainActor
final class WatchCaptureStore: NSObject, ObservableObject {
    static let shared = WatchCaptureStore()

    @Published private(set) var captures: [WatchCapture] = []
    @Published private(set) var isReachable = false
    /// Why the queue is not being saved normally, shown until it resolves.
    @Published private(set) var storageIssue: WatchCaptureQueueIssue?

    private let file: WatchCaptureQueueFile
    private var activated = false
    private lazy var queue: WatchCaptureQueue = self.makeQueue()

    /// Name of the persisted queue inside the shared container.
    private static let queueFileName = "captures.json"

    override private init() {
        // The queue lives in the App Group container so the watch widget
        // extension can read the state its complication renders. Installs that
        // predate the App Group keep their queue via the one-off migration.
        let container = WatchSharedContainer.shared
        container.migrateLegacyFile(named: Self.queueFileName)
        self.file = WatchCaptureQueueFile(fileURL: container.url(named: Self.queueFileName))
        super.init()
        captures = queue.captures
        WatchComplicationPublisher.shared.update(captures: captures)
    }

    private func makeQueue() -> WatchCaptureQueue {
        let queue = WatchCaptureQueue(
            captures: file.open(),
            transport: WatchConnectivityCaptureTransport(),
            audioURL: WatchAudioRecorder.fileURL(for:),
            persist: { [unowned self] captures in self.save(captures) }
        )
        storageIssue = file.issue
        queue.onChange = { [unowned self] captures in self.captures = captures }
        return queue
    }

    /// Reads the saved queue again after it could not be read. While it stays
    /// unreadable nothing is saved over it; new recordings keep their
    /// recovery marker and audio until it can be.
    func reloadQueue() {
        guard storageIssue?.blocksSaving == true else { return }
        queue = makeQueue()
        captures = queue.captures
        WatchComplicationPublisher.shared.update(captures: captures)
        queue.retryPending()
    }

    func dismissStorageNotice() {
        file.dismissNotice()
        storageIssue = file.issue
    }

    // MARK: - Session lifecycle

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Capture queue

    /// Registers a finished recording and hands it to WatchConnectivity.
    @discardableResult
    func enqueue(_ recording: WatchAudioRecorder.FinishedRecording) -> Bool {
        queue.enqueue(id: recording.id, createdAt: recording.createdAt, duration: recording.duration)
    }

    func containsCapture(id: UUID) -> Bool {
        queue.containsCapture(id: id)
    }

    /// Re-queues captures whose transfer never completed (e.g. after the
    /// process was killed mid-transfer). Skips ids WatchConnectivity is
    /// already transferring.
    func retryPending() {
        queue.retryPending()
    }

    // MARK: - Persistence

    /// Every queue mutation funnels through here. A failed or refused write
    /// is reported through `storageIssue`; the queue then keeps its previous
    /// state, and a recording keeps its recovery marker and audio.
    private func save(_ captures: [WatchCapture]) -> Bool {
        defer { storageIssue = file.issue }
        do {
            try file.save(captures)
        } catch {
            return false
        }
        // Publish only the queue state that has reached durable storage.
        WatchComplicationPublisher.shared.update(captures: captures)
        return true
    }
}

/// Adapts `WCSession.default` to the queue's transport contract.
@MainActor
private final class WatchConnectivityCaptureTransport: WatchCaptureTransport {
    var isActivated: Bool { WCSession.default.activationState == .activated }

    func hasOutstandingTransfer(for id: UUID) -> Bool {
        WCSession.default.outstandingFileTransfers.contains {
            WatchCaptureEnvelope.from(metadata: $0.file.metadata)?.id == id
        }
    }

    func transferFile(_ url: URL, envelope: WatchCaptureEnvelope) {
        WCSession.default.transferFile(url, metadata: envelope.metadata())
    }
}

// MARK: - WCSessionDelegate

extension WatchCaptureStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            // An unsuccessful request may be retried by the next explicit entry.
            // Pending requests and successful activation remain deduplicated.
            self.activated = activationState == .activated
            self.isReachable = session.isReachable
            if activationState == .activated {
                self.retryPending()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable {
                // Connectivity came back — re-queue anything that failed while
                // the phone was away.
                self.retryPending()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        guard let id = WatchCaptureEnvelope.from(metadata: fileTransfer.file.metadata)?.id else { return }
        Task { @MainActor in
            self.queue.transferFinished(id: id, error: error)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let ack = WatchCaptureAck.from(userInfo: userInfo) else { return }
        Task { @MainActor in
            self.queue.handleAck(ack)
        }
    }
}
