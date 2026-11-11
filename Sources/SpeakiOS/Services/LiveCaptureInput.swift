#if os(iOS)
import AVFoundation
import SpeakCore

/// The microphone side of one iOS live transcriber: the `AVAudioEngine`, the
/// ownership of its single input tap and of the recording audio session, and
/// the capture-disruption guard.
///
/// ``iOSLiveTranscriber``, ``SharedClientLiveTranscriber`` and
/// ``OpenAIRealtimeLiveTranscriber`` each own one. A route change or an audio
/// session interruption ends capture the same way on every route: the guard
/// disarms itself, stops the engine and removes the tap, then hands the reason
/// to the transcriber, which drains its provider once through its normal stop.
/// An interruption-ended notification never restarts capture.
@MainActor
final class LiveCaptureInput {
    let engine = AVAudioEngine()
    private(set) var hasInputTap = false
    private(set) var ownsAudioSession = false
    private let audioSessionManager: AudioSessionManager
    private let configurationObserver: CaptureDisruptionObserver
    private let interruptionObserver: CaptureDisruptionObserver

    init(audioSessionManager: AudioSessionManager, center: NotificationCenter = .default) {
        self.audioSessionManager = audioSessionManager
        configurationObserver = CaptureDisruptionObserver(center: center)
        interruptionObserver = CaptureDisruptionObserver(center: center)
    }

    var inputNode: AVAudioInputNode { engine.inputNode }

    /// True while this input holds anything a cancel must release.
    var holdsCaptureResources: Bool { ownsAudioSession || hasInputTap }

    /// Configures the recording audio session. The claim is recorded first, so
    /// a configuration that throws or is cancelled is still released.
    func claimAudioSession() async throws {
        ownsAudioSession = true
        try await audioSessionManager.configureForRecording()
    }

    func releaseAudioSession() {
        guard ownsAudioSession else { return }
        audioSessionManager.deactivate()
        ownsAudioSession = false
    }

    /// Installs the run's tap through `install` and records that this input
    /// owns it, so ``removeTap()`` is safe to call on every exit path.
    func installTap(_ install: (AVAudioInputNode) throws -> Void) throws {
        try install(engine.inputNode)
        hasInputTap = true
    }

    func removeTap() {
        guard hasInputTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }

    func startEngine() throws {
        engine.prepare()
        try engine.start()
    }

    /// Stops the engine first, then removes the tap; no new buffers arrive after this.
    func halt() {
        engine.stop()
        removeTap()
    }

    /// Arms the disruption guard for the capture that has just gone live.
    ///
    /// A queued notification is ignored once the guard is disarmed or re-armed
    /// (``CaptureDisruptionObserver`` retires its identity), and when
    /// `isActive` says the owner is no longer running or is already stopping.
    func armDisruptionHandling(
        isActive: @escaping @MainActor () -> Bool,
        onStopped: @escaping @MainActor (iOSTranscriptionError) -> Void
    ) {
        let disrupt: @MainActor (iOSTranscriptionError) -> Void = { [weak self] reason in
            guard let self, isActive() else { return }
            self.disarmDisruptionHandling()
            self.halt()
            onStopped(reason)
        }
        configurationObserver.observe(.AVAudioEngineConfigurationChange, object: engine) { [weak self] in
            self?.engine.isRunning == true
        } onDisruption: {
            disrupt(.microphoneChanged)
        }
        interruptionObserver.observeAudioInterruption {
            disrupt(.interrupted)
        }
    }

    /// Watches only for an engine-configuration change that leaves the engine
    /// stopped, for an owner that keeps its own interruption handling and
    /// stop sequence (hands-free arms that observer before the engine exists).
    /// ``disarmDisruptionHandling()`` retires it.
    func observeConfigurationChanges(onDisruption: @escaping @MainActor () -> Void) {
        configurationObserver.observe(.AVAudioEngineConfigurationChange, object: engine) { [weak self] in
            self?.engine.isRunning == true
        } onDisruption: {
            onDisruption()
        }
    }

    func disarmDisruptionHandling() {
        configurationObserver.stop()
        interruptionObserver.stop()
    }
}
#endif
