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

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?

    private let store: WatchCaptureStore
    private let runtime: WatchRecordingRuntime
    private var recorder: AVAudioRecorder?
    private var currentID = UUID()

    init(
        store: WatchCaptureStore = WatchCaptureStore.shared,
        runtime: WatchRecordingRuntime = WatchRecordingRuntime()
    ) {
        self.store = store
        self.runtime = runtime
        super.init()
        runtime.onRuntimeEnd = { [weak self] reason in
            self?.finish(reason: reason)
        }
    }

    /// Directory holding not-yet-transferred capture audio.
    static var capturesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Captures", isDirectory: true)
    }

    static func fileURL(for id: UUID) -> URL {
        capturesDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("m4a")
    }

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isRecording else { return }
        lastError = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is required. Allow it in the Watch app settings."
            return
        }

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
            guard recorder.record() else {
                throw WatchRecorderError.failedToStart
            }

            self.recorder = recorder
            currentID = id
            startedAt = Date()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
            runtime.end()
        }
    }

    /// User-initiated stop.
    func stop() {
        finish(reason: .userStopped)
    }

    /// Single exit path for a recording. Stops the recorder, releases the
    /// runtime, then lets `WatchRecordingEndPolicy` decide whether the audio
    /// captured so far is worth sending to the iPhone.
    private func finish(reason: WatchRecordingEndReason) {
        guard isRecording, let recorder else { return }
        let createdAt = startedAt ?? Date()
        // `currentTime` reads zero once the recorder is stopped.
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        startedAt = nil
        runtime.end()

        let url = Self.fileURL(for: currentID)
        let outcome = WatchRecordingEndPolicy.outcome(
            for: reason,
            duration: duration,
            hasAudioFile: FileManager.default.fileExists(atPath: url.path)
        )
        lastError = outcome.message

        switch outcome.disposition {
        case .discard:
            try? FileManager.default.removeItem(at: url)
        case .enqueue:
            store.enqueue(
                FinishedRecording(
                    id: currentID,
                    url: url,
                    createdAt: createdAt,
                    duration: duration
                )
            )
        }
    }
}

extension WatchAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let detail = error?.localizedDescription
        Task { @MainActor in
            self.finish(reason: .encodingFailed(reason: detail))
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // A user-initiated stop has already cleared the state, so `finish` is a
        // no-op there. An unsuccessful finish means the system stopped the
        // recorder under us — treat it as lost runtime and keep the partial.
        guard !flag else { return }
        Task { @MainActor in
            self.finish(reason: .runtimeInvalidated(reason: nil))
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
