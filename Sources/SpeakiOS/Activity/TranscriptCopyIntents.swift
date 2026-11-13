#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

// MARK: - Result Row Intents

/// Copies the completed transcript from the Live Activity result row.
///
/// `LiveActivityIntent` conformance is what makes this in-process: without it the
/// widget extension performs the intent itself, and a UI-less extension cannot
/// write the general pasteboard (PBErrorDomain 11). It is the same mechanism the
/// Stop button already relies on.
///
/// The row only shows this button when the payload carries a preview, i.e. when
/// the completed transcript was actually published to the App Group, so the
/// button is never offered for a session whose text cannot be retrieved. The
/// activity is moved to `.copied` only after `UIPasteboard.changeCount` confirms
/// the write landed — nothing else in the app sets that outcome, so a `Copied`
/// row always corresponds to a clipboard write that really happened.
///
/// The intent is *not* parameterless: "the last completed transcript" is a moving
/// target. The activity is reused and a finished row is offered for three
/// minutes, so between rendering a row and tapping it another session can finish
/// and replace what the App Group holds. `completionID` is the id of the
/// completion that rendered the tapped row, and the copy is refused unless the
/// stored transcript is still that completion's — a caller is never handed a
/// different recording's text.
@available(iOS 18, *)
public struct CopyLastTranscriptIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Copy Last Transcript"
    public static var description = IntentDescription(
        """
        The Live Activity's copy button, tied to one completed recording. \
        In your own shortcuts, use Copy Full Transcript or Get Last Transcription.
        """,
        categoryName: "Transcripts"
    )

    public static var openAppWhenRun: Bool = false
    /// Reads and writes private transcript data, so never run on a locked device.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    /// The completion the tapped row was rendered from.
    @Parameter(title: "Completion")
    public var completionID: String

    public init() {}

    public init(completionID: String) {
        self.completionID = completionID
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = SharedTranscriptionState.shared
        // Bound to the row that was tapped, not to whatever finished most
        // recently: a row whose transcript has been superseded refuses rather
        // than copying the newer session's text.
        guard let text = state.completedTranscript(matching: completionID) else {
            return .result(dialog: "That transcript is no longer the latest one. Open the app to find it.")
        }

        let copied = await MainActor.run { Self.copyConfirmingChangeCount(text) }
        guard copied else {
            return .result(dialog: "Couldn’t reach the clipboard. Open the app to copy it.")
        }

        await TranscriptionActivityManager.shared.markCompletionCopied(completionID: completionID)
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return .result(dialog: "Copied \(wordCount) words.")
    }

    /// Writes to the pasteboard and reports whether the system observed the write.
    @MainActor
    static func copyConfirmingChangeCount(
        _ text: String,
        clipboard: TranscriptClipboard = .shared
    ) -> Bool {
        clipboard.copy(text)
    }
}

// MARK: - Copy Intents

/// App Intent to copy the last transcribed sentence to clipboard.
/// Can be triggered from Live Activity, Shortcuts, or Siri.
public struct CopyLastSentenceIntent: AppIntent {
    public static var title: LocalizedStringResource = "Copy Last Sentence"
    public static var description = IntentDescription(
        """
        Copies the last sentence of the current or most recent recording to the clipboard. \
        Recordings saved to History only aren't available here.
        """,
        categoryName: "Transcripts"
    )

    // Make this available from Live Activity
    public static var openAppWhenRun: Bool = false
    /// Returns and copies private transcript data, so never run on a locked device.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    public init() {}

    public func perform() async throws -> some IntentResult {
        let lastSentence = SharedTranscriptionState.shared.lastTranscribedSentence

        guard !lastSentence.isEmpty else {
            return .result(value: "No recent transcription to copy")
        }

        let copied = await MainActor.run { Self.copy(lastSentence) }
        guard copied else { return .result(value: "Couldn’t reach the clipboard. Open the app to copy it.") }

        return .result(value: "Copied: \(lastSentence.prefix(50))...")
    }

    @MainActor
    static func copy(_ text: String, clipboard: TranscriptClipboard = .shared) -> Bool {
        clipboard.copy(text)
    }
}

/// App Intent to copy the full transcript to clipboard.
public struct CopyFullTranscriptIntent: AppIntent {
    public static var title: LocalizedStringResource = "Copy Full Transcript"
    public static var description = IntentDescription(
        """
        Copies the full text of the current or most recent recording to the clipboard. \
        Recordings saved to History only aren't available here; use Get Last Transcription.
        """,
        categoryName: "Transcripts"
    )

    public static var openAppWhenRun: Bool = false
    /// Returns and copies private transcript data, so never run on a locked device.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    public init() {}

    public func perform() async throws -> some IntentResult {
        let fullText = SharedTranscriptionState.shared.currentTranscriptText

        guard !fullText.isEmpty else {
            return .result(value: "No transcription to copy")
        }

        let copied = await MainActor.run { Self.copy(fullText) }
        guard copied else { return .result(value: "Couldn’t reach the clipboard. Open the app to copy it.") }

        let wordCount = fullText.split(separator: " ").count
        return .result(value: "Copied \(wordCount) words")
    }

    @MainActor
    static func copy(_ text: String, clipboard: TranscriptClipboard = .shared) -> Bool {
        clipboard.copy(text)
    }
}
#endif
