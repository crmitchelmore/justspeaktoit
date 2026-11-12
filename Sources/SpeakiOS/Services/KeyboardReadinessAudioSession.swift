#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Holds an explicit foreground-started recording session open while discarding
/// idle buffers. This keeps iOS from suspending the containing app while
/// Instant Dictation is enabled, without sending or saving idle audio.
@MainActor
final class KeyboardReadinessAudioSession {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var isLent = false

    var isRunning: Bool {
        engine.isRunning
    }

    func start() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Same category, mode and options as a background recording start,
        // so a keyboard hand-off never reconfigures this active session from
        // the background (issue #1469).
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: AudioSessionManager.mixableRecordingOptions
        )
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            stop(deactivateAudioSession: true)
            throw KeyboardReadinessAudioError.noInput
        }
        do {
            if !tapInstalled, !isLent {
                try installDiscardTap()
            }
            engine.prepare()
            try engine.start()
        } catch {
            stop(deactivateAudioSession: true)
            throw error
        }
    }

    /// Lends the running engine to one background dictation.
    ///
    /// iOS lets a background app keep a recording going but refuses to start a
    /// new one (`AVAudioSession.ErrorCode.cannotStartRecording`), so a keyboard
    /// hand-off records on this already-running engine instead of starting its
    /// own. The idle discard tap is removed so the dictation can install its
    /// tap on the same input bus; it is put back when the engine is returned.
    func lendRunningEngine() -> LiveCaptureInput.EngineLease? {
        guard engine.isRunning, !isLent else { return nil }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isLent = true
        return LiveCaptureInput.EngineLease(engine: engine) { [weak self] in
            self?.takeBackEngine()
        }
    }

    private func takeBackEngine() {
        isLent = false
        guard engine.isRunning, !tapInstalled else { return }
        try? installDiscardTap()
    }

    private func installDiscardTap() throws {
        let input = engine.inputNode
        try input.installTapSafely(onBus: 0, bufferSize: 4_096, format: input.outputFormat(forBus: 0)) { _, _ in
            // Deliberately discard idle audio. No persistence or network IO.
        }
        tapInstalled = true
    }

    func stop(deactivateAudioSession: Bool) {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

enum KeyboardReadinessAudioError: LocalizedError {
    case noInput

    var errorDescription: String? {
        "No microphone input is available."
    }
}
#endif
