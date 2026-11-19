import Foundation

// MARK: - Watch Recording Controller
//
// Owns one watch recording from start to the capture queue: the start guard,
// the single exit path, relaunch recovery and the marker bookkeeping. The
// watch app supplies AVFoundation, WatchConnectivity and the audio session
// through `WatchRecordingHost`, so these transitions are unit-tested in
// `SpeakWatchCoreTests` with a fake recorder.

/// A recorder the controller owns while it records.
@MainActor
public protocol WatchCaptureRecorder: AnyObject {
    /// Seconds recorded so far. May read zero after a system-driven stop.
    var currentTime: TimeInterval { get }
    /// How the recorder reports ending on its own (an encoder error, or the
    /// system stopping it). Set only while the controller owns the recorder
    /// and cleared before `stop()`, so a released recorder never calls back.
    var onUnexpectedEnd: (@MainActor @Sendable (WatchRecordingEndReason) async -> Void)? { get set }
    func record() -> Bool
    func stop()
}

/// The platform services a watch recording needs.
@MainActor
public protocol WatchRecordingHost {
    associatedtype Recorder: WatchCaptureRecorder

    func requestRecordPermission() async -> Bool
    /// Activates whatever keeps the recording alive in the background. Must
    /// be called in the foreground.
    func beginRuntime() throws
    func endRuntime()
    func makeRecorder(writingTo url: URL) throws -> Recorder
    func inspectAudio(at url: URL) async -> WatchAudioInspection
    func isQueued(captureID: UUID) -> Bool
    /// Durably queues a finished recording for the iPhone.
    func enqueue(_ recording: WatchFinishedRecording) -> Bool
}

/// A stopped recording handed to the capture queue.
public struct WatchFinishedRecording: Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let createdAt: Date
    public let duration: TimeInterval

    public init(id: UUID, url: URL, createdAt: Date, duration: TimeInterval) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.duration = duration
    }
}

/// What the watch UI and complication show about the recorder.
public struct WatchRecorderStatus: Equatable, Sendable {
    public var isRecording: Bool
    public var startedAt: Date?
    public var lastError: String?

    public init(isRecording: Bool = false, startedAt: Date? = nil, lastError: String? = nil) {
        self.isRecording = isRecording
        self.startedAt = startedAt
        self.lastError = lastError
    }
}

/// Where a recording is in its lifecycle.
///
/// `activity` is exclusive: a recorder is idle, recording or finalising. A
/// start is tracked beside it because it legitimately overlaps the others
/// across its suspensions: it waits for the previous stop's finalisation,
/// marks itself recording before `record()`, and finalises inline if
/// `record()` fails. Tracking it separately keeps a second tap from
/// interleaving with any of those (issue #674).
struct WatchRecorderLifecycle<Recorder: AnyObject> {
    enum Activity {
        case idle
        case recording(Recorder, WatchActiveCapture)
        /// The recorder has stopped; the asset is being inspected and queued.
        /// The marker stays on disk until this finishes.
        case finalising(Task<Void, Never>)
    }

    var activity: Activity = .idle
    var isStartInFlight = false

    var recording: (recorder: Recorder, capture: WatchActiveCapture)? {
        guard case .recording(let recorder, let capture) = activity else { return nil }
        return (recorder, capture)
    }

    var finalisation: Task<Void, Never>? {
        guard case .finalising(let task) = activity else { return nil }
        return task
    }
}

@MainActor
public final class WatchRecordingController<Host: WatchRecordingHost> {
    /// Called whenever `status` changes.
    public var onStatusChange: ((WatchRecorderStatus) -> Void)?
    public private(set) var status = WatchRecorderStatus() {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    private let host: Host
    private let registry: WatchActiveCaptureRegistry
    private let capturesDirectory: URL
    private var didRecoverInterruptedCapture = false
    var lifecycle = WatchRecorderLifecycle<Host.Recorder>() {
        didSet {
            // One assignment, so observers never see recording without its
            // start time.
            var next = status
            next.isRecording = lifecycle.recording != nil
            next.startedAt = lifecycle.recording?.capture.startedAt
            status = next
        }
    }

    private var lastError: String? {
        get { status.lastError }
        set { status.lastError = newValue }
    }

    public init(host: Host, registry: WatchActiveCaptureRegistry, capturesDirectory: URL) {
        self.host = host
        self.registry = registry
        self.capturesDirectory = capturesDirectory
    }

    public func fileURL(for id: UUID) -> URL {
        WatchActiveCapture.fileURL(for: id, in: capturesDirectory)
    }

    public func toggle() async {
        if status.isRecording {
            await stop()
        } else {
            await start()
        }
    }

    public func start() async {
        // `isRecording` stays false across the awaits below (finalisation
        // wait, recovery, permission prompt), so two rapid taps could
        // interleave and orphan one capture. Serialise the whole start.
        guard lifecycle.recording == nil, !lifecycle.isStartInFlight else { return }
        lifecycle.isStartInFlight = true
        defer { lifecycle.isStartInFlight = false }
        lastError = nil

        // A stop keeps the marker on disk while it inspects the finished asset.
        // Wait for that work instead of reading the marker as an unrecovered
        // capture, which made a fast stop-then-start look like a failure.
        if let finalisation = lifecycle.finalisation {
            await finalisation.value
        }
        guard lifecycle.finalisation == nil else {
            lastError = "The previous recording is still finishing."
            return
        }
        guard lifecycle.recording == nil else { return }

        await recoverInterruptedCapture()
        switch registry.loadMarker() {
        case .absent:
            break
        case .present:
            lastError = "The previous recording is still waiting to be recovered."
            return
        case .unreadable, .corrupt:
            // Recovery has already said why. Recording would replace the
            // marker, so it waits until the marker can be read or set aside.
            if lastError == nil { lastError = Self.unreadableMarkerMessage }
            return
        }

        guard await host.requestRecordPermission() else {
            lastError = "Microphone access is required. Allow it in the Watch app settings."
            return
        }
        await begin()
    }

    private func begin() async {
        var preparedCapture: WatchActiveCapture?
        do {
            try host.beginRuntime()
            try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

            let capture = WatchActiveCapture(id: UUID(), startedAt: Date())
            preparedCapture = capture
            let recorder = try host.makeRecorder(writingTo: fileURL(for: capture.id))

            // Persist before audio starts flowing. A process kill after this
            // point leaves enough information for relaunch recovery.
            try registry.persist(capture)

            // Only an owned recorder may call back, so one discarded by a
            // throw above never reaches this object.
            recorder.onUnexpectedEnd = { [weak self, weak recorder] reason in
                guard let self, let recorder, self.lifecycle.recording?.recorder === recorder else { return }
                await self.finish(reason: reason)
            }
            lifecycle.activity = .recording(recorder, capture)
            guard recorder.record() else {
                await finish(reason: .encodingFailed(reason: WatchRecorderError.failedToStart.localizedDescription))
                return
            }
        } catch {
            lastError = error.localizedDescription
            if let preparedCapture, registry.load()?.id != preparedCapture.id {
                try? FileManager.default.removeItem(at: fileURL(for: preparedCapture.id))
            }
            lifecycle.activity = .idle
            host.endRuntime()
        }
    }

    /// User-initiated stop.
    public func stop() async {
        await finish(reason: .userStopped)
    }

    /// Single exit path for a recording: a stop, runtime loss, an
    /// interruption or the recorder ending on its own. Detaches and stops the
    /// recorder, releases the runtime, then lets `WatchRecordingEndPolicy`
    /// decide whether the audio captured so far reaches the iPhone.
    public func finish(reason: WatchRecordingEndReason) async {
        guard let recorder = lifecycle.recording?.recorder,
              let ownedCapture = lifecycle.recording?.capture
        else { return }
        let capture = registry.load() ?? ownedCapture
        // Preserve the live value for a user stop. System-driven callbacks may
        // already see zero, so asset inspection remains the fallback.
        let recorderDuration = recorder.currentTime
        // Detach before stopping: stop's own completion callback and anything
        // after it would be ignored anyway, and the recorder must not call
        // back about a recording this controller no longer owns.
        recorder.onUnexpectedEnd = nil
        recorder.stop()

        // The remaining work suspends. Hold it in the lifecycle so `start()`
        // waits for the marker to be reconciled rather than tripping over it.
        let task = Task { @MainActor in
            defer { self.lifecycle.activity = .idle }
            let inspection = await self.host.inspectAudio(at: self.fileURL(for: capture.id))
            let finalisation = WatchRecordingFinaliser.finalise(
                capture: capture,
                reason: reason,
                recorderDuration: recorderDuration,
                inspection: inspection
            )
            self.complete(finalisation, recovery: false)
        }
        lifecycle.activity = .finalising(task)
        host.endRuntime()
        await task.value
    }

    /// Reconciles a capture whose marker survived process termination. A
    /// playable file enters the same persisted transfer queue as a normal
    /// stop; an unusable file is reported visibly before cleanup.
    public func recoverInterruptedCapture() async {
        guard !didRecoverInterruptedCapture else { return }
        didRecoverInterruptedCapture = true
        let capture: WatchActiveCapture
        switch registry.loadMarker() {
        case .absent:
            return
        case .present(let marker):
            capture = marker
        case .unreadable:
            // Possibly locked by data protection. Keep it and try again on the
            // next start rather than mistaking it for no pending recording.
            didRecoverInterruptedCapture = false
            lastError = Self.unreadableMarkerMessage
            return
        case .corrupt:
            setAsideCorruptMarker()
            return
        }

        // A crash between queue persistence and marker cleanup must not create
        // a duplicate transfer on the next launch.
        if host.isQueued(captureID: capture.id) {
            do {
                try registry.clear(matching: capture.id)
            } catch {
                allowRecoveryRetry(for: capture)
                lastError = "Recording was queued, but recovery cleanup was deferred."
            }
            return
        }

        // The path comes from the id, so a marker written before an app update
        // still finds its audio in the new container.
        let inspection = await host.inspectAudio(at: fileURL(for: capture.id))
        let finalisation = WatchRecordingFinaliser.finalise(
            capture: capture,
            reason: .runtimeInvalidated(reason: "Recording ended while the watch app was unavailable."),
            recorderDuration: 0,
            inspection: inspection
        )
        complete(finalisation, recovery: true)
    }

    private func complete(_ finalisation: WatchRecordingFinalisation, recovery: Bool) {
        // The marker holds identity only, so the audio path comes from the id.
        let audioURL = fileURL(for: finalisation.capture.id)

        switch finalisation.outcome.disposition {
        case .discard:
            lastError = finalisation.outcome.message
            do {
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try FileManager.default.removeItem(at: audioURL)
                }
                try registry.clear(matching: finalisation.capture.id)
                // Only fall back to the generic wording. A reason from the
                // policy tells the user more than "could not be recovered".
                if recovery, lastError == nil {
                    lastError = "An interrupted recording could not be recovered."
                }
            } catch {
                allowRecoveryRetry(for: finalisation.capture)
                lastError = "Recording cleanup failed: \(error.localizedDescription)"
            }
        case .enqueue:
            do {
                let recording = WatchFinishedRecording(
                    id: finalisation.capture.id,
                    url: audioURL,
                    createdAt: finalisation.capture.startedAt,
                    duration: finalisation.duration
                )
                let enqueued = try registry.clearAfterSuccessfulEnqueue(matching: recording.id) {
                    host.enqueue(recording)
                }
                guard enqueued else {
                    allowRecoveryRetry(for: finalisation.capture)
                    lastError = "Recording was saved but could not be queued. It will be recovered next time."
                    return
                }
                // Publish the interruption detail only after the queue write.
                // The complication then keeps the durable capture in its
                // sending state while the in-app UI still explains the stop.
                lastError = finalisation.outcome.message
            } catch {
                // The queue write has succeeded; retaining the marker is safe
                // because enqueue is idempotent on capture id at relaunch.
                allowRecoveryRetry(for: finalisation.capture)
                lastError = "Recording was queued, but recovery cleanup was deferred."
            }
        }
    }

    static var unreadableMarkerMessage: String {
        "The previous recording's state couldn't be read yet. Try again in a moment."
    }

    /// A marker that cannot decode names no capture we can finish. Keep its
    /// bytes under another name and tell the user, rather than deleting it or
    /// letting the next recording overwrite it. Audio files are left alone.
    private func setAsideCorruptMarker() {
        do {
            try registry.quarantineCorruptMarker()
            lastError = "The previous recording's state was damaged and has been set aside. "
                + "Its audio is still on the watch."
        } catch {
            didRecoverInterruptedCapture = false
            lastError = "The previous recording's state is damaged and could not be set aside: "
                + error.localizedDescription
        }
    }

    /// A retained marker still owns audio that must be reconciled. Let the next
    /// start retry recovery rather than blocking recording until app relaunch.
    private func allowRecoveryRetry(for capture: WatchActiveCapture) {
        guard registry.load()?.id == capture.id else { return }
        didRecoverInterruptedCapture = false
    }
}

public enum WatchRecorderError: LocalizedError, Equatable {
    case failedToStart

    public var errorDescription: String? {
        switch self {
        case .failedToStart: return "Recording could not be started."
        }
    }
}
