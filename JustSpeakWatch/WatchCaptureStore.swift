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

    private let fileURL: URL
    private var activated = false
    private lazy var queue: WatchCaptureQueue = {
        let queue = WatchCaptureQueue(
            captures: Self.load(from: self.fileURL),
            transport: WatchConnectivityCaptureTransport(),
            audioURL: WatchAudioRecorder.fileURL(for:),
            persist: { [unowned self] captures in self.save(captures) }
        )
        queue.onChange = { [unowned self] captures in self.captures = captures }
        return queue
    }()

    /// Name of the persisted queue inside the shared container.
    private static let queueFileName = "captures.json"

    override private init() {
        // The queue lives in the App Group container so the watch widget
        // extension can read the state its complication renders. Installs that
        // predate the App Group keep their queue via the one-off migration.
        let container = WatchSharedContainer.shared
        container.migrateLegacyFile(named: Self.queueFileName)
        self.fileURL = container.url(named: Self.queueFileName)
        super.init()
        captures = queue.captures
        WatchComplicationPublisher.shared.update(captures: captures)
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

    private static func load(from fileURL: URL) -> [WatchCapture] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WatchCapture].self, from: data)) ?? []
    }

    private func save(_ captures: [WatchCapture]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(captures) else { return false }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: fileURL, options: .atomic)
            // Every mutation funnels through save(), so publish only the
            // queue state that has reached durable storage.
            WatchComplicationPublisher.shared.update(captures: captures)
            return true
        } catch {
            return false
        }
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
