import AVFoundation
import Foundation

/// Records microphone audio on the watch into a local m4a file.
///
/// Recording is buffered entirely on-device; hand-off to the iPhone is the
/// `WatchCaptureStore`'s job, so a capture survives the phone being out of
/// range (or the transfer failing) without losing audio.
///
/// Runtime past the screen turning off comes from `WatchRecordingRuntime`.
/// Every way a recording can end — a tap, an interruption, watchOS pulling the
/// runtime — funnels through `finish(reason:)`, so a capture cut short is
/// queued for the iPhone rather than dropped.
@MainActor
final class WatchAudioRecorder: NSObject, ObservableObject {
    struct FinishedRecording {
        let id: UUID
        let url: URL
        let createdAt: Date
        let duration: TimeInterval
    }

    /// Every path that starts, stops or aborts a recording goes through this
    /// property, so publishing here keeps the watch-face complication honest
    /// without each call site remembering to.
    @Published private(set) var isRecording = false {
        didSet {
            guard oldValue != self.isRecording else { return }
            WatchComplicationPublisher.shared.update(
                isRecording: self.isRecording,
                recordingStartedAt: self.isRecording ? self.startedAt : nil
            )
        }
    }
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String? {
        didSet {
            guard oldValue != self.lastError else { return }
            WatchComplicationPublisher.shared.update(recordingError: self.lastError)
        }
    }

    private let store: WatchCaptureStore
    private let runtime: WatchRecordingRuntime
    private let activeCaptureRegistry: WatchActiveCaptureRegistry
    private var recorder: AVAudioRecorder?
    private var currentID = UUID()
    /// Serialises `start()` across its suspension points (issue #674).
    private var isStarting = false
    private var isFinalising = false
    private var finalisationTask: Task<Void, Never>?
    private var didRecoverInterruptedCapture = false

    init(
        store: WatchCaptureStore? = nil,
        runtime: WatchRecordingRuntime? = nil,
        activeCaptureRegistry: WatchActiveCaptureRegistry? = nil
    ) {
        self.store = store ?? WatchCaptureStore.shared
        self.runtime = runtime ?? WatchRecordingRuntime()
        self.activeCaptureRegistry = activeCaptureRegistry ?? WatchActiveCaptureRegistry(
            fileURL: Self.activeCaptureMarkerURL
        )
        super.init()
        self.runtime.onRuntimeEnd = { [weak self] reason in
            Task { @MainActor in
                await self?.finish(reason: reason)
            }
        }
    }

    /// Directory holding not-yet-transferred capture audio.
    static var capturesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Captures", isDirectory: true)
    }

    /// Derived from the capture id, never persisted: the container path changes
    /// across an app update or a restore, so a stored path would break recovery.
    static func fileURL(for id: UUID) -> URL {
        WatchActiveCapture.fileURL(for: id, in: capturesDirectory)
    }

    private static var activeCaptureMarkerURL: URL {
        capturesDirectory.appendingPathComponent("active-capture.json")
    }

    func toggle() async {
        if isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        // Owned-operation guard (issue #674): `isRecording` stays false across
        // the awaits below (finalisation wait, recovery, permission prompt),
        // so two rapid taps could interleave and replace `recorder` /
        // `currentID`, orphaning one capture. Serialise the whole start.
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil

        // A stop keeps the marker on disk while it inspects the finished asset.
        // Wait for that work instead of reading the marker as an unrecovered
        // capture, which made a fast stop-then-start look like a failure.
        if let finalisationTask {
            await finalisationTask.value
        }
        guard !isFinalising else {
            lastError = "The previous recording is still finishing."
            return
        }
        guard !isRecording else { return }

        await recoverInterruptedCapture()
        guard activeCaptureRegistry.load() == nil else {
            lastError = "The previous recording is still waiting to be recovered."
            return
        }

        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is required. Allow it in the Watch app settings."
            return
        }

        var preparedCapture: WatchActiveCapture?
        do {
            // Activating the audio session in the foreground is what buys the
            // background runtime; watchOS will not let a recording start once
            // the app is already backgrounded.
            try runtime.begin()

            try FileManager.default.createDirectory(
                at: Self.capturesDirectory,
                withIntermediateDirectories: true
            )

            let id = UUID()
            let url = Self.fileURL(for: id)
            let capture = WatchActiveCapture(id: id, startedAt: Date())
            preparedCapture = capture
            // Mono 16 kHz AAC: compact voice-quality audio that keeps
            // WatchConnectivity transfers small (~250 KB per minute).
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self

            // Persist before audio starts flowing. A process kill after this
            // point leaves enough information for relaunch recovery.
            try activeCaptureRegistry.persist(capture)

            self.recorder = recorder
            currentID = id
            startedAt = capture.startedAt
            isRecording = true
            guard recorder.record() else {
                await finish(reason: .encodingFailed(reason: WatchRecorderError.failedToStart.localizedDescription))
                return
            }
        } catch {
            lastError = error.localizedDescription
            if let preparedCapture,
               activeCaptureRegistry.load()?.id != preparedCapture.id
            {
                try? FileManager.default.removeItem(at: Self.fileURL(for: preparedCapture.id))
            }
            recorder = nil
            isRecording = false
            startedAt = nil
            runtime.end()
        }
    }

    /// User-initiated stop.
    func stop() async {
        await finish(reason: .userStopped)
    }

    /// Reconciles a capture whose marker survived process termination. A
    /// playable file enters the same persisted transfer queue as a normal
    /// stop; an unusable file is reported visibly before cleanup.
    func recoverInterruptedCapture() async {
        guard !didRecoverInterruptedCapture else { return }
        didRecoverInterruptedCapture = true
        guard let capture = activeCaptureRegistry.load() else { return }

        // A crash between queue persistence and marker cleanup must not create
        // a duplicate transfer on the next launch.
        if store.containsCapture(id: capture.id) {
            do {
                try activeCaptureRegistry.clear(matching: capture.id)
            } catch {
                allowRecoveryRetry(for: capture)
                lastError = "Recording was queued, but recovery cleanup was deferred."
            }
            return
        }

        // The path comes from the id, so a marker written before an app update
        // still finds its audio in the new container.
        let inspection = await inspectAudio(at: Self.fileURL(for: capture.id))
        let finalisation = WatchRecordingFinaliser.finalise(
            capture: capture,
            reason: .runtimeInvalidated(reason: "Recording ended while the watch app was unavailable."),
            recorderDuration: 0,
            inspection: inspection
        )
        complete(finalisation, recovery: true)
    }

    /// Single exit path for a recording. Stops the recorder, releases the
    /// runtime, then lets `WatchRecordingEndPolicy` decide whether the audio
    /// captured so far is worth sending to the iPhone.
    private func finish(reason: WatchRecordingEndReason) async {
        guard !isFinalising, isRecording, let recorder else { return }
        isFinalising = true
        let capture = activeCaptureRegistry.load()
            ?? WatchActiveCapture(id: currentID, startedAt: startedAt ?? Date())
        // Preserve the live value for a user stop. System-driven delegate
        // callbacks may already see zero, so asset inspection below remains
        // the authoritative fallback.
        let recorderDuration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        startedAt = nil
        runtime.end()

        // The remaining work suspends. Hold it in a task so `start()` can wait
        // for the marker to be reconciled rather than trip over it.
        let task = Task { @MainActor in
            defer { self.isFinalising = false }
            let inspection = await self.inspectAudio(at: Self.fileURL(for: capture.id))
            let finalisation = WatchRecordingFinaliser.finalise(
                capture: capture,
                reason: reason,
                recorderDuration: recorderDuration,
                inspection: inspection
            )
            self.complete(finalisation, recovery: false)
        }
        finalisationTask = task
        await task.value
        if finalisationTask == task { finalisationTask = nil }
    }

    private func complete(_ finalisation: WatchRecordingFinalisation, recovery: Bool) {
        // The marker holds identity only, so the audio path comes from the id.
        let audioURL = Self.fileURL(for: finalisation.capture.id)

        switch finalisation.outcome.disposition {
        case .discard:
            lastError = finalisation.outcome.message
            do {
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try FileManager.default.removeItem(at: audioURL)
                }
                try activeCaptureRegistry.clear(matching: finalisation.capture.id)
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
                let enqueued = try activeCaptureRegistry.clearAfterSuccessfulEnqueue(
                    matching: finalisation.capture.id
                ) {
                    store.enqueue(
                        FinishedRecording(
                            id: finalisation.capture.id,
                            url: audioURL,
                            createdAt: finalisation.capture.startedAt,
                            duration: finalisation.duration
                        )
                    )
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

    /// A retained marker still owns audio that must be reconciled. Let the next
    /// start retry recovery rather than blocking recording until app relaunch.
    private func allowRecoveryRetry(for capture: WatchActiveCapture) {
        guard activeCaptureRegistry.load()?.id == capture.id else { return }
        didRecoverInterruptedCapture = false
    }

    private func inspectAudio(at url: URL) async -> WatchAudioInspection {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else { return .unplayable }

        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let assetDuration = try await asset.load(.duration)
            let duration = assetDuration.seconds
            guard isPlayable, duration.isFinite, duration > 0 else { return .unplayable }
            return WatchAudioInspection(isPlayable: true, duration: duration)
        } catch {
            return .unplayable
        }
    }
}

extension WatchAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let recorderID = ObjectIdentifier(recorder)
        let detail = error?.localizedDescription
        Task { @MainActor in
            guard self.recorder.map(ObjectIdentifier.init) == recorderID else { return }
            await self.finish(reason: .encodingFailed(reason: detail))
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // A user-initiated stop has already cleared the state, so `finish` is a
        // no-op there. An unsuccessful finish means the system stopped the
        // recorder under us — treat it as lost runtime and keep the partial.
        guard !flag else { return }
        let recorderID = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard self.recorder.map(ObjectIdentifier.init) == recorderID else { return }
            await self.finish(reason: .runtimeInvalidated(reason: nil))
        }
    }
}

enum WatchRecorderError: LocalizedError {
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .failedToStart: return "Recording could not be started."
        }
    }
}
