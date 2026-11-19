#if os(iOS)
import Foundation
import SpeakCore

/// The foreground run's Live Activity. Presentation only: the transcript is
/// delivered either way, and every call is a no-op while the user has Live
/// Activities turned off.
@MainActor
struct ForegroundLiveActivity {
    let manager: TranscriptionActivityManager
    let isEnabled: @MainActor () -> Bool

    /// Arms rather than records: the presentation gate promotes it once the
    /// run has proven its own input.
    func arm(provider: String) {
        guard isEnabled() else { return }
        manager.startActivity(provider: provider, initialStatus: .arming)
    }

    typealias Status = TranscriptionActivityAttributes.TranscriptionStatus

    func update(_ status: Status, snippet: String, words: Int, seconds: Int) {
        guard isEnabled() else { return }
        manager.updateActivity(status: status, lastSnippet: snippet, wordCount: words, duration: seconds)
    }

    /// A partial can arrive from pre-roll before this run has seen its own
    /// input, and it must not announce active capture. One delivered by the
    /// drain describes finalisation, never active capture.
    func publishTranscript(_ text: String, finalising: Bool, presentingCapture: Bool, words: Int, seconds: Int) {
        if finalising {
            update(.finalising, snippet: text, words: words, seconds: seconds)
        } else if presentingCapture {
            update(.recording, snippet: text, words: words, seconds: seconds)
        } else {
            update(.arming, snippet: CapturePresentationGate.preparingMessage, words: 0, seconds: 0)
        }
    }

    func reportError(_ error: Error) {
        guard isEnabled() else { return }
        manager.reportError(error.localizedDescription)
    }

    func end() {
        guard isEnabled() else { return }
        manager.endActivity()
    }

    /// The completed row, or an ended activity when the hands-free lane
    /// declines to rearm (#942/#1040).
    func complete(
        _ result: TranscriptionResult, words: Int, seconds: Int,
        rearmHandsFree: (@MainActor () -> Bool)?, stopNotice: String?
    ) {
        guard isEnabled() else { return }
        let shouldRearm = rearmHandsFree?() == true
        if rearmHandsFree != nil, !shouldRearm {
            // End synchronously so an old completion cannot clear a later arm's activity.
            manager.endActivity()
        } else {
            manager.completeActivity(
                finalWordCount: words,
                duration: seconds,
                keepPrimed: shouldRearm && stopNotice == nil,
                primedMessage: stopNotice ?? "Hands-free armed",
                primedStatus: shouldRearm ? .armed : .idle,
                completionOutcome: .unconfirmed(transcript: result.text),
                resultPreview: TranscriptionResultRow.preview(for: result.text)
            )
        }
    }
}
#endif
