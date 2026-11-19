import AVFoundation
import Foundation
import SpeakWatchCore

/// Records microphone audio on the watch into a local m4a file.
///
/// Recording is buffered entirely on-device; hand-off to the iPhone is the
/// `WatchCaptureStore`'s job, so a capture survives the phone being out of
/// range (or the transfer failing) without losing audio.
///
/// The lifecycle (start guard, single exit path, recovery) lives in
/// `WatchRecordingController` (SpeakWatchCore). This type supplies
/// AVFoundation, the runtime and the store, and publishes the status for the
/// UI and the watch-face complication. Every way a recording can end — a tap,
/// an interruption, watchOS pulling the runtime — funnels through the
/// controller's `finish(reason:)`, so a capture cut short is queued for the
/// iPhone rather than dropped.
@MainActor
final class WatchAudioRecorder: ObservableObject {
    typealias FinishedRecording = WatchFinishedRecording

    /// Every path that starts, stops or aborts a recording changes this
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

    private let controller: WatchRecordingController<WatchAudioRecordingHost>

    init(
        store: WatchCaptureStore? = nil,
        runtime: WatchRecordingRuntime? = nil,
        activeCaptureRegistry: WatchActiveCaptureRegistry? = nil
    ) {
        let runtime = runtime ?? WatchRecordingRuntime()
        controller = WatchRecordingController(
            host: WatchAudioRecordingHost(store: store ?? WatchCaptureStore.shared, runtime: runtime),
            registry: activeCaptureRegistry ?? WatchActiveCaptureRegistry(fileURL: Self.activeCaptureMarkerURL),
            capturesDirectory: Self.capturesDirectory
        )
        controller.onStatusChange = { [weak self] status in self?.apply(status) }
        runtime.onRuntimeEnd = { [weak self] reason in
            Task { @MainActor in
                await self?.controller.finish(reason: reason)
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
        await controller.toggle()
    }

    func start() async {
        await controller.start()
    }

    /// User-initiated stop.
    func stop() async {
        await controller.stop()
    }

    /// Reconciles a capture whose marker survived process termination.
    func recoverInterruptedCapture() async {
        await controller.recoverInterruptedCapture()
    }

    private func apply(_ status: WatchRecorderStatus) {
        // A new start time must be in place before `isRecording` publishes it.
        if status.startedAt != nil { startedAt = status.startedAt }
        isRecording = status.isRecording
        startedAt = status.startedAt
        lastError = status.lastError
    }
}

/// AVFoundation, the audio-session runtime and the capture store, as the
/// controller sees them.
@MainActor
struct WatchAudioRecordingHost: WatchRecordingHost {
    let store: WatchCaptureStore
    let runtime: WatchRecordingRuntime

    func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Activating the audio session in the foreground is what buys the
    /// background runtime; watchOS will not let a recording start once the
    /// app is already backgrounded.
    func beginRuntime() throws {
        try runtime.begin()
    }

    func endRuntime() {
        runtime.end()
    }

    func makeRecorder(writingTo url: URL) throws -> WatchAVAudioRecorder {
        try WatchAVAudioRecorder(url: url)
    }

    func inspectAudio(at url: URL) async -> WatchAudioInspection {
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

    func isQueued(captureID: UUID) -> Bool {
        store.containsCapture(id: captureID)
    }

    func enqueue(_ recording: WatchFinishedRecording) -> Bool {
        store.enqueue(recording)
    }
}

/// One `AVAudioRecorder`, acting as its own delegate only while the controller
/// owns it.
@MainActor
final class WatchAVAudioRecorder: NSObject, WatchCaptureRecorder {
    private let recorder: AVAudioRecorder

    var onUnexpectedEnd: (@MainActor @Sendable (WatchRecordingEndReason) async -> Void)? {
        // AVFoundation must not message a delegate about a recorder the
        // controller has released.
        didSet { recorder.delegate = onUnexpectedEnd == nil ? nil : self }
    }

    init(url: URL) throws {
        // Mono 16 kHz AAC: compact voice-quality audio that keeps
        // WatchConnectivity transfers small (~250 KB per minute).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        super.init()
    }

    var currentTime: TimeInterval { recorder.currentTime }

    func record() -> Bool { recorder.record() }

    func stop() { recorder.stop() }
}

extension WatchAVAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let detail = error?.localizedDescription
        Task { @MainActor in await self.onUnexpectedEnd?(.encodingFailed(reason: detail)) }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // A user-initiated stop has already detached the delegate. An
        // unsuccessful finish means the system stopped the recorder under us —
        // treat it as lost runtime and keep the partial.
        guard !flag else { return }
        Task { @MainActor in await self.onUnexpectedEnd?(.runtimeInvalidated(reason: nil)) }
    }
}
