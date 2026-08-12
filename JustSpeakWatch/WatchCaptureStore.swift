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
/// out of range), deletes local audio once delivery is confirmed, and applies
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
    /// Acks that arrived before WatchConnectivity confirmed delivery, keyed by
    /// capture id, applied once the transfer completes.
    private var pendingAcks: [UUID: WatchCaptureAck] = [:]

    override private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = base.appendingPathComponent("captures.json")
        super.init()
        load()
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
    func enqueue(_ recording: WatchAudioRecorder.FinishedRecording) {
        let capture = WatchCapture(
            id: recording.id,
            createdAt: recording.createdAt,
            duration: recording.duration,
            status: .recorded
        )
        captures.insert(capture, at: 0)
        prune()
        save()
        startTransfer(for: capture.id)
    }

    /// Re-queues captures whose transfer never completed (e.g. after the
    /// process was killed mid-transfer). Skips ids WatchConnectivity is
    /// already transferring.
    func retryPending() {
        for capture in captures where capture.status == .recorded || capture.status == .failed {
            startTransfer(for: capture.id)
        }
    }

    private func startTransfer(for id: UUID) {
        guard let capture = captures.first(where: { $0.id == id }) else { return }
        // Only a capture that is not already in flight may be queued; anything
        // else would hand WatchConnectivity a second copy of the same audio.
        guard capture.status == .recorded || capture.status == .failed else { return }
        guard WCSession.default.activationState == .activated else { return }
        guard !hasOutstandingTransfer(for: id) else {
            transition(id, to: .transferring)
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

    private func transition(_ id: UUID, to status: WatchCaptureStatus, message: String? = nil) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        guard captures[index].status.canTransition(to: status) else { return }
        captures[index].status = status
        captures[index].message = message
        save()
    }

    private func handleTransferFinished(id: UUID, error: Error?) {
        if let error {
            transition(id, to: .failed, message: error.localizedDescription)
            scheduleRetry(for: id)
            return
        }
        retryAttempts[id] = nil
        // Delivery confirmed at the WatchConnectivity layer — the local audio
        // copy is no longer needed.
        transition(id, to: .delivered)
        try? FileManager.default.removeItem(at: WatchAudioRecorder.fileURL(for: id))
        if let ack = pendingAcks.removeValue(forKey: id) {
            apply(ack)
        }
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
            try? await Task.sleep(for: .seconds(delay))
            self?.startTransfer(for: id)
        }
    }

    private func handleAck(_ ack: WatchCaptureAck) {
        guard let capture = captures.first(where: { $0.id == ack.id }) else { return }
        // `transferUserInfo` can outrun the file-transfer completion callback.
        // The state machine rejects transferring → transcribed, so hold the
        // ack and replay it once delivery lands.
        guard capture.status != .transferring else {
            pendingAcks[ack.id] = ack
            return
        }
        apply(ack)
    }

    private func apply(_ ack: WatchCaptureAck) {
        switch ack.outcome {
        case .transcribed:
            retryAttempts[ack.id] = nil
            transition(ack.id, to: .transcribed)
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

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(captures) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
