import Foundation

// MARK: - Watch Capture Queue
//
// The watch-side transfer queue state machine: which captures exist, when one
// is handed to the transport, how transport and transcription callbacks move
// it through `WatchCaptureStatus`, bounded in-process retries and pruning.
//
// Pure Foundation. WatchConnectivity, the persisted file and the complication
// stay in the watch app's `WatchCaptureStore`, which injects them here, so the
// rules are unit-tested in `SpeakWatchCoreTests` without watch hardware.

/// One capture as tracked (and persisted) on the watch. The persisted queue is
/// a JSON array of these, so the coding keys are a storage format.
public struct WatchCapture: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let duration: TimeInterval
    public var status: WatchCaptureStatus
    /// Failure reason surfaced in the list, when `status == .failed`.
    public var message: String?

    public init(
        id: UUID,
        createdAt: Date,
        duration: TimeInterval,
        status: WatchCaptureStatus,
        message: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.status = status
        self.message = message
    }
}

/// The part of `WCSession` the queue uses. The watch app adapts
/// `WCSession.default`; tests supply a deterministic double.
@MainActor
public protocol WatchCaptureTransport: AnyObject {
    /// Whether the session is activated and may accept a transfer.
    var isActivated: Bool { get }
    /// True while the transport still holds a queued transfer for `id`, so a
    /// second transfer would deliver the audio twice.
    func hasOutstandingTransfer(for id: UUID) -> Bool
    /// Hands `url` to the transport's durable queue.
    func transferFile(_ url: URL, envelope: WatchCaptureEnvelope)
}

/// Owns capture state transitions. Every mutation that must survive process
/// death goes through `persist`; a failed write restores the previous state.
@MainActor
public final class WatchCaptureQueue {
    /// Terminal captures beyond this count are pruned oldest-first.
    public static let maxTrackedCaptures = 30

    /// Bounded in-process retries for a transfer that fails while the app is
    /// still running (activation-time `retryPending()` covers process death).
    public static let maxTransferRetries = 3

    /// Runs `action` after `delay`. The default sleeps on a task; tests fire it
    /// by hand so retry timing is deterministic.
    public typealias RetryScheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> Void

    /// Captures newest-first. Observers see every change, including a revert
    /// after a failed write.
    public private(set) var captures: [WatchCapture] {
        didSet { onChange?(captures) }
    }

    /// Called after `captures` changes.
    public var onChange: (([WatchCapture]) -> Void)?

    private let transport: WatchCaptureTransport
    private let audioURL: (UUID) -> URL
    private let fileExists: (URL) -> Bool
    private let removeFile: (URL) -> Void
    private let persist: ([WatchCapture]) -> Bool
    private let scheduleRetry: RetryScheduler
    private var retryAttempts: [UUID: Int] = [:]

    public init(
        captures: [WatchCapture],
        transport: WatchCaptureTransport,
        audioURL: @escaping (UUID) -> URL,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        removeFile: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) },
        persist: @escaping ([WatchCapture]) -> Bool,
        scheduleRetry: RetryScheduler? = nil
    ) {
        self.captures = captures
        self.transport = transport
        self.audioURL = audioURL
        self.fileExists = fileExists
        self.removeFile = removeFile
        self.persist = persist
        self.scheduleRetry = scheduleRetry ?? Self.sleepThenRun
    }

    private static func sleepThenRun(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            action()
        }
    }

    // MARK: - Capture queue

    /// Registers a finished recording and hands it to the transport. Returns
    /// false only when the new entry could not be persisted.
    @discardableResult
    public func enqueue(id: UUID, createdAt: Date, duration: TimeInterval) -> Bool {
        if captures.contains(where: { $0.id == id }) {
            startTransfer(for: id)
            return true
        }

        let previousCaptures = captures
        captures.insert(
            WatchCapture(id: id, createdAt: createdAt, duration: duration, status: .recorded),
            at: 0
        )
        prune()
        guard persist(captures) else {
            captures = previousCaptures
            return false
        }
        startTransfer(for: id)
        return true
    }

    public func containsCapture(id: UUID) -> Bool {
        captures.contains { $0.id == id }
    }

    /// Re-queues captures whose transfer never completed (e.g. after the
    /// process was killed mid-transfer). Skips ids the transport is already
    /// transferring.
    public func retryPending() {
        for capture in captures {
            if capture.status.canReleaseAudio {
                // Also recover a crash between durable acknowledgement and deletion.
                removeFile(audioURL(capture.id))
            } else {
                startTransfer(for: capture.id)
            }
        }
    }

    // MARK: - Transport and acknowledgement callbacks

    /// A transport transfer finished, successfully when `error` is nil.
    public func transferFinished(id: UUID, error: Error?) {
        // An early transcription acknowledgement wins over any late callback.
        guard let capture = captures.first(where: { $0.id == id }), !capture.status.isTerminal else { return }
        if let error {
            transition(id, to: .failed, message: error.localizedDescription)
            scheduleBoundedRetry(for: id)
            return
        }
        retryAttempts[id] = nil
        // Transport completion does not prove the phone parked the file or
        // durably imported it. Retain our recovery copy until its success ack.
        transition(id, to: .delivered)
    }

    public func handleAck(_ ack: WatchCaptureAck) {
        guard let capture = captures.first(where: { $0.id == ack.id }) else { return }
        switch ack.outcome {
        case .transcribed:
            // Persist even an early acknowledgement immediately. Buffering it
            // in memory loses the only success signal if the process dies.
            let durable = capture.status.canReleaseAudio || transition(ack.id, to: .transcribed)
            guard durable else { return }
            retryAttempts[ack.id] = nil
            removeFile(audioURL(ack.id))
        case .failed:
            transition(ack.id, to: .failed, message: ack.message ?? "Transcription failed on iPhone")
        }
    }

    // MARK: - State transitions

    private func startTransfer(for id: UUID) {
        guard let capture = captures.first(where: { $0.id == id }) else { return }
        guard transport.isActivated else { return }
        guard capture.status.shouldRetryTransfer(hasOutstandingTransfer: transport.hasOutstandingTransfer(for: id))
        else { return }

        let url = audioURL(capture.id)
        guard fileExists(url) else { return }

        let envelope = WatchCaptureEnvelope(
            id: capture.id,
            createdAt: capture.createdAt,
            duration: capture.duration
        )
        transport.transferFile(url, envelope: envelope)
        transition(capture.id, to: .transferring)
    }

    @discardableResult
    private func transition(_ id: UUID, to status: WatchCaptureStatus, message: String? = nil) -> Bool {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return false }
        guard captures[index].status.canTransition(to: status) else { return false }
        let previous = captures[index]
        captures[index].status = status
        captures[index].message = message
        guard persist(captures) else {
            captures[index] = previous
            return false
        }
        return true
    }

    /// Re-queues a transfer that failed while the process is still running.
    /// `retryPending()` only runs on activation, so without this a mid-session
    /// failure would stay failed until the app is relaunched.
    private func scheduleBoundedRetry(for id: UUID) {
        let attempt = (retryAttempts[id] ?? 0) + 1
        guard attempt <= Self.maxTransferRetries else { return }
        retryAttempts[id] = attempt
        scheduleRetry(pow(2.0, Double(attempt))) { [weak self] in
            self?.startTransfer(for: id)
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
