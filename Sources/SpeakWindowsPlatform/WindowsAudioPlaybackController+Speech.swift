import Foundation

/// Read aloud speaks a History record as consecutive segments, each
/// synthesised before it plays. A speech keeps that record the one audible
/// owner from the click to its last segment: while a segment is synthesised
/// or between segments, the record's display stays active (preparing, or
/// paused), so Pause and Stop remain available however long synthesis takes.
extension WindowsAudioPlaybackController {
    /// One Read aloud of a History record, from `beginSpeech` until it ends.
    public struct Speech: Hashable, Sendable {
        public let recordID: UUID
        let id: UUID
    }

    /// A speech in progress, under `lock`.
    struct SpeechState {
        let speech: Speech
        var paused = false

        /// Nothing is audible, so the speech acknowledges its own pause.
        var display: WindowsAudioPlaybackDisplay {
            WindowsAudioPlaybackDisplay(
                recordID: speech.recordID, state: paused ? .paused : .preparing,
                text: WindowsAudioPlaybackDisplay.text(position: 0, duration: nil)
            )
        }
    }

    /// Starts Read aloud of `recordID` before its first segment is
    /// synthesised. The current playback stops now, and the record's display
    /// shows speech until `endSpeech`, or until Stop, another row, recording
    /// or import, a History playback, another speech or close ends it. Play
    /// each segment with `playToCompletion(_:path:)`; segments of an ended
    /// speech are refused.
    public func beginSpeech(recordID: UUID) throws -> Speech {
        try lock.withLock {
            guard !closed else { throw WindowsAudioPlaybackError("The app is closing.") }
            if let run = current { stopLocked(run) }
            let state = SpeechState(speech: Speech(recordID: recordID, id: UUID()))
            speechState = state
            publishLocked(state.display)
            return state.speech
        }
    }

    /// Ends `speech` once its last segment has played or its reader stopped.
    /// A speech that has already ended or been replaced is left alone.
    public func endSpeech(_ speech: Speech) {
        lock.withLock {
            if speechState?.speech == speech { endSpeechLocked() }
        }
    }

    /// With a run still current, its release presents idle instead.
    func endSpeechLocked(presenting: Bool = true) {
        guard let state = speechState else { return }
        speechState = nil
        guard presenting, current == nil else { return }
        publishLocked(WindowsAudioPlaybackDisplay(
            recordID: state.speech.recordID, state: .idle,
            text: WindowsAudioPlaybackDisplay.text(position: 0, duration: nil)
        ))
    }

    /// Between segments, Pause and Play act on the speech itself.
    func toggleSpeechPauseLocked(recordID: UUID) -> Bool {
        guard var state = speechState, state.speech.recordID == recordID else { return false }
        state.paused.toggle()
        speechState = state
        publishLocked(state.display)
        return true
    }
}

extension WindowsAudioPlaybackController.Run {
    /// A segment of paused speech starts paused and is shown paused, so it
    /// is never heard before the user resumes.
    func continueSpeech(_ state: WindowsAudioPlaybackController.SpeechState) {
        pauseRequested = state.paused
        guard state.paused else { return }
        display = WindowsAudioPlaybackDisplay(recordID: recordID, state: .paused, text: display.text)
    }
}
