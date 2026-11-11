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
            if !tapInstalled {
                try input.installTapSafely(onBus: 0, bufferSize: 4_096, format: format) { _, _ in
                    // Deliberately discard idle audio. No persistence or network IO.
                }
                tapInstalled = true
            }
            engine.prepare()
            try engine.start()
        } catch {
            stop(deactivateAudioSession: true)
            throw error
        }
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
