// Hands-free ("armed") dictation: the pure arming state machine and the
// voice-activity debounce that drives it. Both types are free of AV, Speech
// and availability dependencies so they compile and unit-test on every OS.
// The SpeechDetector bridge that feeds them lives in
// AppleSpeechAnalyzerTranscriber.swift.
import Foundation

extension HandsFreeDictationMachine.Failure {
    /// Classifies a thrown session error. Unknown errors are treated as capture
    /// failures so arming always disarms with a message rather than hanging.
    public init(_ error: Error) {
        guard let modelError = error as? AppleLocalModelError else {
            self = .captureFailed
            return
        }
        switch modelError {
        case .speechDetectorUnavailable, .speechDetectorFailed, .speechTranscriberUnavailable:
            self = .detectorUnavailable
        case .localeUnsupported:
            self = .localeUnsupported
        case .modelAssetsUnavailable:
            self = .assetsUnavailable
        case .compatibleAudioFormatUnavailable:
            self = .audioUnavailable
        case .foundationModelUnavailable, .emptyTranscript:
            self = .captureFailed
        }
    }

    /// User-facing reason shown when arming or capture fails. Hands-free must
    /// never fail silently: a failed arm looks identical to a quiet room.
    public var message: String {
        switch self {
        case .detectorUnavailable:
            return "Hands-free dictation needs Apple's on-device speech detector, "
                + "which isn't available on this device."
        case .assetsUnavailable:
            return "Hands-free dictation couldn't install Apple's on-device speech models."
        case .localeUnsupported:
            return "Hands-free dictation doesn't support this language on this device."
        case .audioUnavailable:
            return "Hands-free dictation couldn't access the microphone."
        case .captureFailed:
            return "Hands-free dictation stopped because the recording session failed."
        case .unsupportedConfiguration:
            return "Hands-free dictation requires an Apple on-device streaming model."
        }
    }
}

/// Timings for hands-free dictation, kept in one pure place so the state
/// machine, the detector session and the UI agree on the same budgets.
public enum HandsFreeDictationPolicy {
    /// Target latency from the user starting to speak to capture running.
    /// The detector reports speech itself, so this is the budget the audio tap
    /// and session start have to fit inside — asserted on device, not in code.
    public static let speechStartBudgetSeconds: Double = 0.3

    /// How long the detector must report silence before capture auto-stops.
    /// Long enough to survive a mid-sentence breath, short enough that the
    /// transcript lands without the user reaching for the hotkey.
    public static let defaultSilenceHoldSeconds: Double = 2.0

    /// Audio retained only in memory while a capture starts, so the first
    /// phoneme is included once speech is confirmed.
    public static let preRollSeconds: Double = 0.5

    /// Detector sensitivity used when arming. `.medium` trades a little
    /// eagerness for far fewer false starts in a noisy room.
    public static let sensitivity: AppleSpeechDetectorSensitivity = .medium

    public static func silenceHoldSeconds(configured value: TimeInterval) -> TimeInterval {
        min(max(value, 0.5), 5.0)
    }

    public static func supportsCapture(modelID: String, isStreaming: Bool) -> Bool {
        isStreaming && AppleLocalModels.isSpeechAnalyzerModel(modelID)
    }
}

/// Turns a stream of voice-activity samples into the discrete edges the
/// arming machine consumes.
///
/// Speech is reported on the leading edge so capture starts as soon as the
/// detector is confident; silence is reported only after it has held for
/// ``HandsFreeDictationPolicy/silenceHoldSeconds``, so a pause for breath does
/// not end the utterance.
public struct HandsFreeVoiceActivityTracker: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case quiet
        case speaking
        case silent(since: Double)
    }

    private var phase: Phase = .quiet

    public init() {}

    /// Feeds one detector sample. `seconds` is a monotonically increasing
    /// timeline position (the detector's result range end).
    public mutating func observe(
        speechDetected: Bool,
        atSeconds seconds: Double,
        silenceHoldSeconds: Double = HandsFreeDictationPolicy.defaultSilenceHoldSeconds
    ) -> HandsFreeDictationMachine.Event? {
        guard speechDetected else { return observeSilence(atSeconds: seconds, hold: silenceHoldSeconds) }
        switch phase {
        case .speaking:
            return nil
        case .quiet, .silent:
            phase = .speaking
            return .speechDetected
        }
    }

    private mutating func observeSilence(atSeconds seconds: Double, hold: Double) -> HandsFreeDictationMachine.Event? {
        switch phase {
        case .quiet:
            return nil
        case .speaking:
            phase = .silent(since: seconds)
            return nil
        case .silent(let since):
            // Clamp so a non-monotonic or reset timeline cannot report silence
            // early; it just restarts the hold window.
            guard seconds - since >= hold else {
                if seconds < since { phase = .silent(since: seconds) }
                return nil
            }
            phase = .quiet
            return .silenceElapsed
        }
    }

    /// Drops any part-observed utterance, e.g. when the session re-arms.
    public mutating func reset() {
        phase = .quiet
    }
}

/// Pure state machine for hands-free dictation.
///
/// The session owner feeds it detector edges and user intent; it returns the
/// effects to perform. It knows nothing about audio, Speech or the OS version
/// gate, so every transition is unit-testable.
public struct HandsFreeDictationMachine: Equatable, Sendable {
    /// The runtime state is distinct from the persisted preference. `arming`
    /// remains visible until permission, assets and the audio engine are ready.
    public enum State: Equatable, Sendable {
        case off
        case arming
        case armed
        case recording
        case finalising
    }

    public enum Failure: String, Equatable, Sendable {
        /// The OS or device has no SpeechDetector (below OS 26, or unsupported).
        case detectorUnavailable
        /// Detector or transcription assets could not be installed.
        case assetsUnavailable
        /// The requested locale has no on-device model.
        case localeUnsupported
        /// The microphone or audio session could not be acquired.
        case audioUnavailable
        /// The transcription session failed while armed.
        case captureFailed
        /// A legacy, remote or batch transcription engine is selected.
        case unsupportedConfiguration
    }

    public enum Event: Equatable, Sendable {
        /// Compatibility input for callers that expose a single toggle action.
        case userToggled
        case userArmed
        case userDisarmed
        case detectorStarted
        /// The detector reported the leading edge of speech.
        case speechDetected
        /// Silence has held long enough to end the utterance.
        case silenceElapsed
        /// The capture pipeline finished on its own (final transcript delivered).
        case captureFinished
        /// Arming or capture failed; hands-free drops back to disarmed.
        case sessionFailed(Failure)
    }

    public enum Effect: Equatable, Sendable {
        case startDetector
        case stopDetector
        case startCapture
        case stopCapture
        case cancelCapture
        case reportFailure(Failure)
    }

    public private(set) var state: State = .off
    /// The failure that last disarmed the session, for HUD/status messaging.
    /// Cleared whenever the user arms again.
    public private(set) var lastFailure: Failure?

    public init() {}

    public var isArmed: Bool { state != .off }
    public var isRecording: Bool { state == .recording }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .userToggled:
            return state == .off ? handle(.userArmed) : handle(.userDisarmed)
        case .userArmed:
            guard state == .off else { return [] }
            lastFailure = nil
            state = .arming
            return [.startDetector]
        case .userDisarmed:
            return handleUserDisarmed()
        case .detectorStarted:
            guard state == .arming else { return [] }
            state = .armed
            return []
        case .speechDetected:
            guard state == .armed else { return [] }
            state = .recording
            return [.startCapture]
        case .silenceElapsed:
            guard state == .recording else { return [] }
            state = .finalising
            return [.stopCapture]
        case .captureFinished:
            guard state == .finalising else { return [] }
            state = .armed
            return []
        case .sessionFailed(let failure):
            return handleFailure(failure)
        }
    }

    private mutating func handleUserDisarmed() -> [Effect] {
        switch state {
        case .off:
            return []
        case .arming, .armed:
            state = .off
            return [.stopDetector]
        case .recording, .finalising:
            state = .off
            return [.cancelCapture, .stopDetector]
        }
    }

    /// Convenience for call sites holding a thrown error rather than a reason.
    public mutating func handle(sessionError: Error) -> [Effect] {
        handle(.sessionFailed(Failure(sessionError)))
    }

    private mutating func handleFailure(_ failure: Failure) -> [Effect] {
        guard state != .off else { return [] }
        let hadCapture = state == .recording || state == .finalising
        state = .off
        lastFailure = failure
        return (hadCapture ? [.cancelCapture] : []) + [.stopDetector, .reportFailure(failure)]
    }
}

public enum HandsFreeCaptureStartOutcome: Equatable, Sendable {
    case started
    case rejected(HandsFreeDictationMachine.Failure)
}

public enum HandsFreeCaptureEndOutcome: Equatable, Sendable {
    case completed
    case failed(HandsFreeDictationMachine.Failure)
}
