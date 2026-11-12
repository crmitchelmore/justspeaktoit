import SpeakCore

/// The words the keyboard strip shows when no live text is on it.
///
/// Every line is a fixed local string, so nothing a provider or the app sends
/// is ever rendered over the host app.
enum KeyboardStatusCopy {
    static func direct(_ state: KeyboardDictationMachine.State) -> String {
        switch state {
        case .idle:
            return "Tap the mic and speak. Words appear as you talk."
        case .starting:
            return "Starting the microphone…"
        case .recording:
            return "Listening…"
        case .stopping:
            return "Finishing…"
        case .finished:
            return "Inserted. Tap the mic to dictate more."
        case let .failed(failure):
            return Self.failure(failure)
        }
    }

    static func blocked(_ reason: KeyboardLaunchPolicy.BlockReason) -> String {
        switch reason {
        case .fullAccessRequired:
            return "Turn on Allow Full Access for Just Speak in Settings › General › Keyboard to dictate."
        case .sharedContainerUnavailable:
            return "Open the Just Speak app once, then try this keyboard again."
        }
    }

    static func failure(_ failure: KeyboardDictationMachine.Failure) -> String {
        switch failure {
        case .microphoneUnavailable:
            return "The keyboard can't use the microphone. Allow it in Settings, "
                + "or open Just Speak and enable Instant Dictation."
        case .speechRecognitionUnavailable:
            return "Speech recognition isn't available. Allow it in Settings, then try again."
        case .audioInterrupted:
            return "Audio was interrupted. Tap the mic to try again."
        case .targetChanged:
            return "The text field changed, so dictation stopped. Tap the mic to continue here."
        case .noSpeech:
            return "No speech detected. Tap the mic and try again."
        }
    }

    static func handoff(
        _ presentation: KeyboardHandoffController.Presentation,
        endReason: InstantDictationReadinessEndReason?
    ) -> String {
        switch presentation {
        case .idle:
            return "Instant Dictation ready. Tap the mic to speak."
        case .starting:
            return "Connecting to Just Speak…"
        case .waitingForApp:
            // A recorded terminal reason says which of microphone exhaustion,
            // session-window expiry or store failure ended readiness; without
            // one the generic reconnect prompt still stands (issue #995).
            guard let endReason else {
                return "Open Just Speak once to reconnect Instant Dictation, then return here."
            }
            return endReason.readinessMessage
        case .recording:
            return "Listening via Just Speak…"
        case .transcribing:
            return "Finishing transcript…"
        case .inserted:
            return "Inserted. Tap the mic to dictate more."
        case .unavailable:
            return "Just Speak is unavailable. Open the app once, then tap the mic to retry."
        case .cancelled:
            return "Cancelled. Nothing was inserted."
        case .targetChanged:
            return "The text field changed, so nothing was inserted. Tap the mic to retry."
        case let .error(code):
            return Self.handoffError(code)
        }
    }

    static func handoffError(_ code: KeyboardHandoffRecord.FailureCode) -> String {
        switch code {
        case .fullAccessRequired:
            return "Turn on Full Access in Settings, then try again."
        case .appUnavailable:
            // Also how a background microphone refusal arrives (issue #1469):
            // iOS only lets Just Speak take the microphone again once it has
            // been opened.
            return "iOS paused Just Speak's microphone. Open Just Speak, then return here and tap the mic."
        case .recordingUnavailable:
            return "Just Speak couldn't start recording. Tap the mic to retry."
        case .noSpeech:
            return "No speech detected. Nothing was inserted."
        case .timedOut:
            return "The request expired. Tap the mic to retry."
        case .invalidRequest, .unknown:
            return "The handoff ended safely. Tap the mic to retry."
        case .targetChanged:
            return "The destination changed, so nothing was inserted. Tap the mic to retry."
        case .profileUnavailable:
            // Reported both before recording (missing model or credentials,
            // nothing recorded) and after a failed polish (raw transcript saved
            // to History), so the copy must hold for either.
            return "This profile is unavailable. Open Just Speak to check its model and credentials. "
                + "Anything already recorded is saved in the app's History."
        }
    }
}
