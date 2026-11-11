#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import SpeakCore

/// The hands-free detector's microphone for one arm: a ``LiveCaptureInput``
/// whose single tap feeds the pre-roll and the on-device speech detector, and
/// whose engine-configuration guard reports a lost route.
///
/// ``IOSHandsFreeDictationCoordinator`` keeps every lifecycle decision — run
/// identity, stop reason and the audio-session claim — and its own
/// interruption observer, which must already be armed while the detector is
/// still being prepared. This type owns only the audio resources it starts.
@MainActor
final class HandsFreeDetectorCapture {
    /// A detector already detached from its engine, cancelled by the owner
    /// once the rest of teardown has run.
    struct Retired {
        fileprivate let session: Any?

        func cancel() async {
            if #available(iOS 26.0, *), let session = session as? AppleSpeechDetectorSession {
                await session.cancel()
            }
        }
    }

    private let audioSessionManager: AudioSessionManager
    private var input: LiveCaptureInput?
    private var detectorSession: Any?

    init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
    }

    var hasEngine: Bool { input != nil }
    var isRunning: Bool { input?.engine.isRunning == true }

    /// Starts a fresh engine whose tap feeds `preRoll` and `session`. On any
    /// failure the tap is removed and the detector cancelled before throwing.
    @available(iOS 26.0, *)
    func start(
        session: AppleSpeechDetectorSession,
        preRoll: HandsFreeAudioPreRollBuffer,
        onConfigurationDisruption: @escaping @MainActor () -> Void
    ) async throws {
        let input = LiveCaptureInput(audioSessionManager: audioSessionManager)
        let inputFormat = input.inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            await session.cancel()
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }
        do {
            let converter = try AppleSpeechAudioConverter(
                sourceFormat: inputFormat,
                targetFormat: session.audioFormat
            )
            try input.installTap { node in
                try node.installTapSafely(onBus: 0, bufferSize: 4096, format: inputFormat) { [preRoll] buffer, _ in
                    preRoll.append(buffer)
                    if let converted = converter.convert(buffer) {
                        session.send(converted)
                    }
                }
            }
            try input.startEngine()
            self.input = input
            detectorSession = session
            input.observeConfigurationChanges(onDisruption: onConfigurationDisruption)
        } catch {
            input.engine.stop()
            input.inputNode.removeTap(onBus: 0)
            await session.cancel()
            throw error
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
