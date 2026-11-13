#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import SpeakCore

/// The hands-free detector's microphone for one arm: a ``LiveCaptureInput``
/// whose single tap feeds the pre-roll and the on-device energy voice-activity
/// gate (no Speech framework module runs while armed), and
/// whose engine-configuration guard reports a lost route.
///
/// ``IOSHandsFreeDictationCoordinator`` keeps every lifecycle decision — run
/// identity, stop reason and the audio-session claim — and its own
/// interruption observer, which must already be armed while the detector is
/// still being prepared. This type owns only the audio resources it starts.
/// The microphone route or engine could not start, as opposed to a Speech
/// framework failure.
enum HandsFreeDetectorCaptureError: Error, Equatable {
    case microphoneUnavailable
}

@MainActor
final class HandsFreeDetectorCapture {
    /// A detector already detached from its engine, cancelled by the owner
    /// once the rest of teardown has run.
    struct Retired {
        fileprivate let session: HandsFreeVoiceActivitySession?

        func cancel() async {
            session?.cancel()
        }
    }

    private let audioSessionManager: AudioSessionManager
    private var input: LiveCaptureInput?
    private var detectorSession: HandsFreeVoiceActivitySession?

    init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
    }

    var hasEngine: Bool { input != nil }
    var isRunning: Bool { input?.engine.isRunning == true }

    /// Starts a fresh engine whose tap feeds `preRoll` and `session`. On any
    /// failure the tap is removed and the detector cancelled before throwing.
    func start(
        session: HandsFreeVoiceActivitySession,
        preRoll: HandsFreeAudioPreRollBuffer,
        onConfigurationDisruption: @escaping @MainActor () -> Void
    ) async throws {
        let input = LiveCaptureInput(audioSessionManager: audioSessionManager)
        let inputFormat = input.inputNode.outputFormat(forBus: 0)
        guard AppleLocalModels.isUsableAudioFormat(
            sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount
        ) else {
            session.cancel()
            throw HandsFreeDetectorCaptureError.microphoneUnavailable
        }
        do {
            try input.installTap { node in
                try node.installTapSafely(onBus: 0, bufferSize: 4096, format: inputFormat) { [preRoll] buffer, _ in
                    preRoll.append(buffer)
                    session.send(buffer)
                }
            }
            try input.startEngine()
            self.input = input
            detectorSession = session
            input.observeConfigurationChanges(onDisruption: onConfigurationDisruption)
        } catch {
            input.engine.stop()
            input.inputNode.removeTap(onBus: 0)
            session.cancel()
            throw HandsFreeDetectorCaptureError.microphoneUnavailable
        }
    }

    /// Stops reacting to configuration changes and stops the engine, leaving
    /// the tap and detector for ``tearDown()``.
    func pause() {
        input?.disarmDisruptionHandling()
        input?.engine.stop()
    }

    func stopObservingConfiguration() {
        input?.disarmDisruptionHandling()
    }

    /// Starts a new utterance after a capture, keeping the learned noise floor.
    func resetSpeech() {
        detectorSession?.resetSpeech()
    }

    /// Restarts the engine after an utterance's capture has released it.
    func resume() throws {
        guard let input else {
            throw AppleLocalModelError.speechDetectorFailed
        }
        if !input.engine.isRunning {
            try input.startEngine()
        }
    }

    /// Stops the engine, removes the tap and detaches the detector.
    func tearDown() -> Retired {
        input?.engine.stop()
        input?.inputNode.removeTap(onBus: 0)
        input = nil
        let retired = Retired(session: detectorSession)
        detectorSession = nil
        return retired
    }
}
#endif
