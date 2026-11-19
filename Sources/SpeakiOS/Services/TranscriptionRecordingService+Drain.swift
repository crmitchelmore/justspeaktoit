#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Drains the active transcriber at stop and picks the best text it left.
@MainActor
extension TranscriptionRecordingService {
    /// Stops whichever transcriber is currently active and returns its result.
    /// Falls back to a synthetic `TranscriptionResult` built from `partialText`
    /// if no transcriber is wired up (defensive — shouldn't happen in practice).
    ///
    /// We null out the transcriber property **before** awaiting `stop()` to be
    /// safe under `@MainActor` reentrancy: a rapid double-press of the Action
    /// Button can re-enter `stopRecording` while the first stop is suspended,
    /// and otherwise both calls would see the same non-nil transcriber and try
    /// to stop it twice.
    func drainActiveTranscriber(duration: Int) async -> TranscriptionResult {
        if let session = transcriptionSession {
            transcriptionSession = nil
            stoppingSession = session
            let warningRunID = recordingWarningRunID
            defer {
                stoppingSession = nil
                // The drained writer's final summary replaces the initial notice
                // unless a newer run already owns the surface (issue #950).
                if recordingWarningRunID == warningRunID { recordingWarning = session.recordingLossSummary }
            }
            do {
                guard let result = try await boundedStop(of: session) else {
                    // The stop was abandoned, so nothing here delivers this
                    // capture: its recording stays on disk to be recovered.
                    return timedOutFinalisationResult(for: session, duration: duration)
                }
                // This transcript is about to be delivered, so this capture's
                // temporary recording may be discarded once that has happened.
                deliveringSession = session
                return result
            } catch {
                handleError(error, session: session)
                return syntheticResult(duration: TimeInterval(duration))
            }
        }
        return syntheticResult(text: partialText, duration: TimeInterval(duration))
    }

    /// The most complete transcript we can produce at stop time. The transcriber
    /// result is preferred, but for very short recordings the provider may return
    /// empty while interim text is still held in `partialText` — falling back
    /// there keeps the clipboard and dialog honest. We deliberately do NOT fall
    /// back to the last completed transcript: a silent new session must stay
    /// empty rather than re-emitting the previous recording's text.
    func bestAvailableText(from result: TranscriptionResult) -> String {
        TranscriptionRecordingService.bestTranscript(
            candidates: [result.text, partialText],
            fallback: ""
        )
    }

    /// Begins a finite-length background assertion so a headless / backgrounded
    /// process isn't suspended before the clipboard (and any post-processing)
    /// write commits. The returned object ends the task exactly once.
    func beginBackgroundAssertion(_ name: String) -> BackgroundTaskAssertion {
        BackgroundTaskAssertion(name: name)
    }

    /// A result with no provider payload: a stop that had nothing to drain, or
    /// a drain that failed. Always tagged with the run's model.
    func syntheticResult(text: String = "", duration: TimeInterval = 0) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            segments: [],
            confidence: nil,
            duration: duration,
            modelIdentifier: currentModel,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }
}
#endif
