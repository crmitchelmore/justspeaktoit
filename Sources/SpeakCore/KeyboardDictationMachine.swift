import Foundation

/// Chooses how the keyboard captures speech for the current appearance.
///
/// Both paths require Full Access: without it iOS gives the keyboard neither
/// an audio session nor the shared App Group container, so nothing can run.
/// With Full Access the keyboard prefers recording in its own process and
/// falls back to the containing app's Instant Dictation handoff when the
/// microphone or Apple Speech is unavailable to the extension.
public enum KeyboardCapturePlanner {
    public enum Permission: Equatable, Sendable {
        case undetermined
        case granted
        case denied
    }

    public enum Path: Equatable, Sendable {
        /// Record and transcribe inside the keyboard extension.
        case direct
        /// Fall back to the containing app's Instant Dictation handoff.
        case handoff
        /// Neither path can run; show setup guidance.
        case blocked(KeyboardLaunchPolicy.BlockReason)
    }

    /// `undetermined` permissions still plan `direct`: the capture engine asks
    /// for them on the first mic tap and reports failure if refused.
    public static func path(
        hasFullAccess: Bool,
        sharedContainerAvailable: Bool,
        microphonePermission: Permission,
        speechRecognitionPermission: Permission,
        speechRecognizerAvailable: Bool
    ) -> Path {
        if let reason = KeyboardLaunchPolicy.blockReason(
            hasFullAccess: hasFullAccess,
            sharedContainerAvailable: sharedContainerAvailable
        ) {
            return .blocked(reason)
        }
        guard speechRecognizerAvailable,
              microphonePermission != .denied,
              speechRecognitionPermission != .denied else {
            return .handoff
        }
        return .direct
    }
}

/// Pure state machine for in-keyboard dictation.
///
/// The keyboard view model feeds it UI and capture-engine events; it returns
/// the effects to perform (start/stop the engine, apply a document edit). All
/// transcript bookkeeping lives in an embedded ``KeyboardTranscriptStreamer``,
/// so the machine plus streamer are fully unit-testable without UIKit, audio,
/// or Speech dependencies.
public struct KeyboardDictationMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case recording
        case stopping
        /// The finished transcript is being rewritten by the selected
        /// dictation profile's on-device cleanup pass.
        case polishing
        case finished
        case failed(Failure)
    }

    public enum Failure: String, Equatable, Sendable {
        case microphoneUnavailable
        case speechRecognitionUnavailable
        case audioInterrupted
        case targetChanged
        case noSpeech
    }

    public enum Event: Equatable, Sendable {
        /// The user tapped the mic key. Toggles: starts when idle, stops when
        /// recording, aborts while still starting.
        case micTapped
        case captureStarted
        case captureFailed(Failure)
        /// A live partial result containing the full transcript so far.
        case hypothesis(String)
        case stopTapped
        /// The engine delivered the final transcript (may be empty).
        case finalized(String)
        /// The selected profile's cleanup pass started on the inserted text.
        case polishStarted
        /// The cleanup pass returned a rewritten transcript.
        case polished(String)
        /// The cleanup pass failed, was cancelled, or is no longer safe to
        /// apply. The raw transcript stays exactly as dictated.
        case polishFailed
        /// The audio session was interrupted (call, Siri, route loss).
        case interrupted
        /// The host text field or selection changed mid-session.
        case targetChanged
        /// The keyboard is disappearing.
        case dismissed
    }

    public enum Effect: Equatable, Sendable {
        case startCapture
        case stopCapture
        case cancelCapture
        case applyEdit(KeyboardTranscriptEdit)
    }

    public private(set) var state: State = .idle
    private var streamer = KeyboardTranscriptStreamer()

    public init() {}

    /// Text inserted into the document during the active session.
    public var liveText: String {
        streamer.insertedText
    }

    public var isCapturing: Bool {
        state == .starting || state == .recording || state == .stopping
    }

    public var isPolishing: Bool {
        state == .polishing
    }

    /// Capture or post-processing is in flight, so quick-switch chips and the
    /// editing keys must stay disabled.
    public var isBusy: Bool {
        isCapturing || isPolishing
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .micTapped:
            return handleMicTapped()
        case .captureStarted, .captureFailed, .hypothesis:
            return handleCaptureEvent(event)
        case .stopTapped:
            return handleStopTapped()
        case let .finalized(text):
            return handleFinalized(text)
        case .polishStarted, .polished, .polishFailed:
            return handlePolishEvent(event)
        case .interrupted:
            return endEarly(reason: .audioInterrupted)
        case .targetChanged:
            return endEarly(reason: .targetChanged)
        case .dismissed:
            let wasCapturing = isCapturing
            state = .idle
            streamer.reset()
            return wasCapturing ? [.cancelCapture] : []
        }
    }

    private mutating func handleCaptureEvent(_ event: Event) -> [Effect] {
        switch event {
        case .captureStarted:
            guard state == .starting else { return [] }
            state = .recording
            return []
        case let .captureFailed(failure):
            guard isCapturing else { return [] }
            state = .failed(failure)
            return [.cancelCapture]
        case let .hypothesis(text):
            guard state == .recording || state == .stopping else { return [] }
            let edit = streamer.update(hypothesis: text)
            return edit.isNoop ? [] : [.applyEdit(edit)]
        default:
            return []
        }
    }

    /// Post-processing only ever rewrites a transcript this session already
    /// inserted, so every polish event outside ``State/polishing`` (and the
    /// ``Event/polishStarted`` that enters it from ``State/finished``) is
    /// ignored rather than applied late.
    private mutating func handlePolishEvent(_ event: Event) -> [Effect] {
        switch event {
        case .polishStarted:
            guard state == .finished else { return [] }
            state = .polishing
            return []
        case let .polished(text):
            guard state == .polishing else { return [] }
            state = .finished
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let edit = streamer.replaceInserted(with: trimmed)
            return edit.isNoop ? [] : [.applyEdit(edit)]
        case .polishFailed:
            guard state == .polishing else { return [] }
            state = .finished
            return []
        default:
            return []
        }
    }

    private mutating func handleMicTapped() -> [Effect] {
        switch state {
        case .idle, .finished, .failed:
            streamer.reset()
            state = .starting
            return [.startCapture]
        case .recording, .starting:
            return handleStopTapped()
        case .stopping, .polishing:
            return []
        }
    }

    private mutating func handleStopTapped() -> [Effect] {
        switch state {
        case .recording:
            state = .stopping
            return [.stopCapture]
        case .starting:
            state = .idle
            streamer.reset()
            return [.cancelCapture]
        default:
            return []
        }
    }

    private mutating func handleFinalized(_ transcript: String) -> [Effect] {
        guard state == .recording || state == .stopping else { return [] }
        let edit = streamer.finalize(transcript: transcript)
        let inserted = streamer.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        state = inserted.isEmpty ? .failed(.noSpeech) : .finished
        return edit.isNoop ? [] : [.applyEdit(edit)]
    }

    /// Ends a session for an external reason. Text already streamed into the
    /// document is kept and committed; an empty session surfaces the failure.
    private mutating func endEarly(reason: Failure) -> [Effect] {
        guard isCapturing else { return [] }
        let inserted = streamer.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inserted.isEmpty {
            state = .failed(reason)
        } else {
            _ = streamer.finalize(transcript: streamer.insertedText)
            state = .finished
        }
        return [.cancelCapture]
    }
}
