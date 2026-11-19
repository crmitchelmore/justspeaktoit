#if os(iOS)
import Foundation

/// One completed capture as the result row shows it, and what the activity
/// returns to afterwards when it stays primed for the Action Button.
struct TranscriptionActivityCompletion {
    let finalWordCount: Int
    let duration: Int
    let keepPrimed: Bool
    let primedMessage: String
    let primedStatus: TranscriptionActivityAttributes.TranscriptionStatus
    let outcome: TranscriptionCompletionOutcome
    let resultPreview: String
    /// The capture receipt (issue #1008); nil keeps the outcome's own message.
    let message: String?
    let resultCompletionID: String
}
#endif
