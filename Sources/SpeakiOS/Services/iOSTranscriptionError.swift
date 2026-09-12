#if os(iOS)
import Foundation
import SpeakCore

// swiftlint:disable type_name
/// Error types for iOS live transcription.
public enum iOSTranscriptionError: LocalizedError {
    case permissionDenied(Permission)
    case recognizerUnavailable
    case audioSessionFailed(Error)
    case recognitionFailed(Error)
    case microphoneChanged
    case interrupted
    case liveActivityUnavailable
    /// A start never reached its backend inside
    /// `CaptureWatchdogPolicy.startDeadlineSeconds`. Carries the last startup
    /// boundary the run actually crossed, so the failure names where it stalled
    /// (issue #993).
    case startTimedOut(after: StartupStage?)
    /// The audio engine started and its input tap then delivered no buffer at
    /// all. A silent room still delivers buffers, so this is a dead microphone
    /// rather than a quiet one (issue #993).
    case microphoneDeliveredNoAudio
    /// A stop waited out `CaptureWatchdogPolicy.finalisationDeadlineSeconds`
    /// without the provider finalising (issue #993).
    case finalisationTimedOut

    public enum Permission {
        case microphone
        case speechRecognition
    }

    var isControlledInterruption: Bool {
        if case .interrupted = self { return true }
        return false
    }

    var endsCapture: Bool {
        switch self {
        case .interrupted, .microphoneChanged: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(.microphone):
            return "Microphone permission is required for transcription."
        case .permissionDenied(.speechRecognition):
            return "Speech recognition permission is required."
        case .recognizerUnavailable:
            return "Speech recognizer is not available for the selected language."
        case .audioSessionFailed:
            return "The microphone audio session could not start. Try again after other audio activity finishes."
        case .recognitionFailed:
            return "Speech recognition failed. Try again, or open the app to check your setup."
        case .microphoneChanged:
            return "The microphone changed and recording stopped."
        case .interrupted:
            return "Recording stopped because audio was interrupted."
        case .liveActivityUnavailable:
            return "A Live Activity could not be started. Open Just Speak to It to continue recording. "
                + "If Live Activities are disabled, enable them in Settings."
        case .startTimedOut(let stage):
            guard let stage else {
                return "Recording did not start in time and was cancelled before it got going."
            }
            return "Recording did not start in time and was cancelled after \(Self.describe(stage))."
        case .microphoneDeliveredNoAudio:
            return "The microphone delivered no audio, so recording stopped."
        case .finalisationTimedOut:
            return "The transcript did not finish in time. Any text already received was kept."
        }
    }

    /// Names the last start boundary a stalled run crossed, in the words a
    /// user can act on rather than the log's closed-set label.
    static func describe(_ stage: StartupStage) -> String {
        switch stage {
        case .credentialsReady: return "loading credentials"
        case .audioSessionConfigured: return "configuring audio"
        case .engineStarted: return "starting the microphone"
        case .sessionStarted: return "starting the transcriber"
        case .firstPartial: return "receiving the first words"
        }
    }
}
// swiftlint:enable type_name
#endif
