import AVFoundation
import Foundation

/// Records microphone audio on the watch into a local m4a file.
///
/// Recording is buffered entirely on-device; hand-off to the iPhone is the
/// `WatchCaptureStore`'s job, so a capture survives the phone being out of
/// range (or the transfer failing) without losing audio.
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

    private var recorder: AVAudioRecorder?
    private var currentID = UUID()

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

    func toggle(store: WatchCaptureStore) async {
        if isRecording {
            stop(store: store)
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

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
            deactivateSession()
        }
    }

    func stop(store: WatchCaptureStore) {
        guard isRecording, let recorder else { return }
        let createdAt = startedAt ?? Date()
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        startedAt = nil
        deactivateSession()

        let finished = FinishedRecording(
            id: currentID,
            url: Self.fileURL(for: currentID),
            createdAt: createdAt,
            duration: duration
        )
        guard duration > 0.2, FileManager.default.fileExists(atPath: finished.url.path) else {
            // Accidental tap — do not queue an empty capture.
            try? FileManager.default.removeItem(at: finished.url)
            return
        }
        store.enqueue(finished)
    }

    /// Terminal failure path for recorder errors the user did not initiate:
    /// clears the recording state so the UI cannot stay stuck in the
    /// recording pose, and discards the unusable partial file.
    private func abortRecording(message: String) {
        guard isRecording else { return }
        lastError = message
        recorder?.stop()
        recorder = nil
        isRecording = false
        startedAt = nil
        deactivateSession()
        try? FileManager.default.removeItem(at: Self.fileURL(for: currentID))
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension WatchAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "Audio encoding failed"
        Task { @MainActor in
            self.lastError = message
            self.abortRecording(message: message)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // A user-initiated stop clears the state itself; only unsuccessful
        // finishes (interruption, encoder failure) need the terminal path.
        guard !flag else { return }
        Task { @MainActor in
            self.abortRecording(message: "Recording stopped unexpectedly.")
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
