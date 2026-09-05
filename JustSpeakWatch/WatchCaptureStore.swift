import Foundation
import WatchConnectivity

/// One capture as tracked (and persisted) on the watch.
struct WatchCapture: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    var status: WatchCaptureStatus
    /// Failure reason surfaced in the list, when `status == .failed`.
    var message: String?
}

/// Owns the watch-side capture queue: persists capture metadata, hands audio
/// files to WatchConnectivity (whose transfer queue survives the phone being
/// out of range), retains local audio until transcription is acknowledged, and applies
/// transcription acknowledgements coming back from the iPhone.
@MainActor
final class WatchCaptureStore: NSObject, ObservableObject {
    static let shared = WatchCaptureStore()

    @Published private(set) var captures: [WatchCapture] = []
    @Published private(set) var isReachable = false

    /// Terminal captures beyond this count are pruned oldest-first.
    static let maxTrackedCaptures = 30

    /// Bounded in-process retries for a transfer that fails while the app is
    /// still running (activation-time `retryPending()` covers process death).
    static let maxTransferRetries = 3

    private let fileURL: URL
    private var activated = false
    private var retryAttempts: [UUID: Int] = [:]

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
        load()
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
        if captures.contains(where: { $0.id == recording.id }) {
            startTransfer(for: recording.id)
            return true
        }

        let previousCaptures = captures
        let capture = WatchCapture(
            id: recording.id,
            createdAt: recording.createdAt,
            duration: recording.duration,
            status: .recorded
        )
        captures.insert(capture, at: 0)
        prune()
        guard save() else {
            captures = previousCaptures
            return false
        }
        startTransfer(for: capture.id)
        return true
    }

    func containsCapture(id: UUID) -> Bool {
        captures.contains { $0.id == id }
    }

    /// Re-queues captures whose transfer never completed (e.g. after the
    /// process was killed mid-transfer). Skips ids WatchConnectivity is
    /// already transferring.
    func retryPending() {
        for capture in captures {
            if capture.status.canReleaseAudio {
                // Also recover a crash between durable acknowledgement and deletion.
                try? FileManager.default.removeItem(at: WatchAudioRecorder.fileURL(for: capture.id))
            } else {
                startTransfer(for: capture.id)
            }
        }
    }

    private func startTransfer(for id: UUID) {
        guard let capture = captures.first(where: { $0.id == id }) else { return }
        guard WCSession.default.activationState == .activated else { return }
        guard capture.status.shouldRetryTransfer(hasOutstandingTransfer: hasOutstandingTransfer(for: id)) else {
            return
        }

        let envelope = WatchCaptureEnvelope(
            id: capture.id,
            createdAt: capture.createdAt,
            duration: capture.duration
        )
        let url = WatchAudioRecorder.fileURL(for: capture.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        WCSession.default.transferFile(url, metadata: envelope.metadata())
        transition(capture.id, to: .transferring)
    }

    /// True while WatchConnectivity still holds a queued transfer for this
    /// capture, so a second `transferFile` would deliver the audio twice.
    private func hasOutstandingTransfer(for id: UUID) -> Bool {
        WCSession.default.outstandingFileTransfers.contains {
            WatchCaptureEnvelope.from(metadata: $0.file.metadata)?.id == id
        }
    }

    // MARK: - State transitions

    @discardableResult
    private func transition(_ id: UUID, to status: WatchCaptureStatus, message: String? = nil) -> Bool {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return false }
        guard captures[index].status.canTransition(to: status) else { return false }
        let previous = captures[index]
        captures[index].status = status
        captures[index].message = message
        guard save() else {
            captures[index] = previous
            return false
        }
        return true
    }

    private func handleTransferFinished(id: UUID, error: Error?) {
        // An early transcription acknowledgement wins over any late callback.
        guard let capture = captures.first(where: { $0.id == id }), !capture.status.isTerminal else { return }
        if let error {
            transition(id, to: .failed, message: error.localizedDescription)
            scheduleRetry(for: id)
            return
        }
        retryAttempts[id] = nil
        // Transport completion does not prove the phone parked the file or
        // durably imported it. Retain our recovery copy until its success ack.
        transition(id, to: .delivered)
    }

    /// Re-queues a transfer that failed while the process is still running.
    /// `retryPending()` only runs on activation, so without this a mid-session
    /// failure would stay failed until the app is relaunched.
    private func scheduleRetry(for id: UUID) {
        let attempt = (retryAttempts[id] ?? 0) + 1
        guard attempt <= Self.maxTransferRetries else { return }
        retryAttempts[id] = attempt
        let delay = pow(2.0, Double(attempt))
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            self?.startTransfer(for: id)
        }
    }

    private func handleAck(_ ack: WatchCaptureAck) {
        guard let capture = captures.first(where: { $0.id == ack.id }) else { return }
        switch ack.outcome {
        case .transcribed:
            // Persist even an early acknowledgement immediately. Buffering it
            // in memory loses the only success signal if the process dies.
            let durable = capture.status.canReleaseAudio || transition(ack.id, to: .transcribed)
            guard durable else { return }
            retryAttempts[ack.id] = nil
            try? FileManager.default.removeItem(at: WatchAudioRecorder.fileURL(for: ack.id))
        case .failed:
            transition(ack.id, to: .failed, message: ack.message ?? "Transcription failed on iPhone")
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        captures = (try? decoder.decode([WatchCapture].self, from: data)) ?? []
    }

    @discardableResult
    private func save() -> Bool {
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

    private func prune() {
        guard captures.count > Self.maxTrackedCaptures else { return }
        // Drop oldest terminal captures first; never drop ones still in flight.
        var excess = captures.count - Self.maxTrackedCaptures
        for capture in captures.reversed() where excess > 0 && capture.status.isTerminal {
            captures.removeAll { $0.id == capture.id }
            excess -= 1
        }
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
            self.handleTransferFinished(id: id, error: error)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let ack = WatchCaptureAck.from(userInfo: userInfo) else { return }
        Task { @MainActor in
            self.handleAck(ack)
        }
    }
}
