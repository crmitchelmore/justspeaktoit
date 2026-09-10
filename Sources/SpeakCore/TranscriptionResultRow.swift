import Foundation

/// The completed Live Activity result row, derived only from what a payload can prove.
///
/// The row never invents an outcome: its headline is always the message of the
/// `TranscriptionCompletionOutcome` already resolved at completion. It only offers
/// an action when the payload carries evidence that the action can succeed — a
/// non-empty preview means the completed transcript was published to the App Group
/// and is therefore retrievable by `CopyLastTranscriptIntent`. Keyboard handoffs and
/// silent sessions publish nothing, so they get a headline and no buttons rather
/// than a button that would fail or a claim that nothing happened.
public struct TranscriptionResultRow: Equatable, Sendable {
    /// Longest transcript prefix carried in the ActivityKit payload.
    public static let previewCharacterLimit = 200

    /// Headline: exactly the resolved outcome's message, never a re-worded claim.
    public let outcomeMessage: String
    /// First line of the transcript, truncated; `nil` when nothing was published.
    public let preview: String?
    /// `nil` when the count would not be meaningful (silence, or no words).
    public let wordCountText: String?
    /// Whether a Copy button may be shown.
    public let offersCopy: Bool
    /// Whether an Open link may be shown.
    public let offersOpen: Bool
    /// Imperative while the clipboard is untouched; "Copy again" once it is confirmed.
    public let copyTitle: String

    /// Builds the row for a completed state, or `nil` when the session is not finished.
    public init?(state: TranscriptionActivityAttributes.ContentState) {
        guard state.status == .completed else { return nil }
        let outcome = state.completionOutcome
        let trimmedPreview = state.resultPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmedPreview.isEmpty ? nil : trimmedPreview
        // Silence can never carry a retrievable transcript, so refuse both actions
        // even if a stale preview survived in the payload.
        let hasRetrievableTranscript = preview != nil && outcome != .noSpeech

        self.outcomeMessage = outcome.message
        self.preview = outcome == .noSpeech ? nil : preview
        self.wordCountText = Self.wordCountText(state.wordCount, outcome: outcome)
        self.offersCopy = hasRetrievableTranscript
        self.offersOpen = hasRetrievableTranscript
        self.copyTitle = outcome == .copied ? "Copy again" : "Copy"
    }

    private static func wordCountText(_ count: Int, outcome: TranscriptionCompletionOutcome) -> String? {
        guard outcome != .noSpeech, count > 0 else { return nil }
        return count == 1 ? "1 word" : "\(count) words"
    }

    /// First non-blank line of `transcript`, truncated to `limit` characters.
    /// Returns "" when there is nothing to show, which suppresses the row's actions.
    public static func preview(for transcript: String, limit: Int = previewCharacterLimit) -> String {
        let firstLine = transcript
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard firstLine.count > limit else { return firstLine }
        return String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
