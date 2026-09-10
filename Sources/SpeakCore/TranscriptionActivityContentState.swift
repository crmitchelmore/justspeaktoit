import Foundation

// MARK: - Content State

/// The dynamic half of a transcription Live Activity: everything the Lock
/// Screen row and the Dynamic Island read, and the only part that changes
/// while a capture runs. Split from the attributes so the manager's file
/// stays readable.
extension TranscriptionActivityAttributes {
    /// The state a Live Activity renders, updated as a capture progresses.
    public struct ContentState: Codable, Hashable {
        /// Current transcription status
        public var status: TranscriptionStatus
        /// Most recent text snippet (last ~100 chars for compact display)
        public var lastSnippet: String
        /// Number of words transcribed so far
        public var wordCount: Int
        /// Duration in seconds
        public var duration: Int
        /// Provider being used
        public var provider: String
        /// Optional error message
        public var errorMessage: String?
        /// Only describes confirmed completion effects; older payloads remain neutral.
        public var completionOutcome: TranscriptionCompletionOutcome
        /// First line of the completed transcript, empty unless it was published
        /// to the App Group and is therefore retrievable by the result actions.
        public var resultPreview: String
        /// Identifies the completion whose transcript this row is offering.
        ///
        /// A Live Activity is reused across sessions and a finished row stays on
        /// screen for `TranscriptionActivityManager.resultRowDuration`, so "the
        /// last completed transcript" is not the same thing as "the transcript
        /// this row was rendered from". The row's Copy action carries this id and
        /// the App Group stores it beside the published text, so a row can only
        /// ever copy its own completion. Empty when nothing retrievable was
        /// published, and absent from payloads written before this existed.
        public var resultCompletionID: String

        public init(
            status: TranscriptionStatus = .idle,
            lastSnippet: String = "",
            wordCount: Int = 0,
            duration: Int = 0,
            provider: String = "Apple Speech",
            errorMessage: String? = nil,
            completionOutcome: TranscriptionCompletionOutcome = .ready,
            resultPreview: String = "",
            resultCompletionID: String = ""
        ) {
            self.status = status
            self.lastSnippet = lastSnippet
            self.wordCount = wordCount
            self.duration = duration
            self.provider = provider
            self.errorMessage = errorMessage
            self.completionOutcome = completionOutcome
            self.resultPreview = resultPreview
            self.resultCompletionID = resultCompletionID
        }

        private enum CodingKeys: String, CodingKey { // swiftlint:disable:this nesting
            case status, lastSnippet, wordCount, duration, provider, errorMessage
            case completionOutcome, resultPreview, resultCompletionID
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.status = try container.decode(TranscriptionStatus.self, forKey: .status)
            self.lastSnippet = try container.decode(String.self, forKey: .lastSnippet)
            self.wordCount = try container.decode(Int.self, forKey: .wordCount)
            self.duration = try container.decode(Int.self, forKey: .duration)
            self.provider = try container.decode(String.self, forKey: .provider)
            self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            self.completionOutcome = try container.decodeIfPresent(
                TranscriptionCompletionOutcome.self, forKey: .completionOutcome
            ) ?? .ready
            self.resultPreview = try container.decodeIfPresent(String.self, forKey: .resultPreview) ?? ""
            self.resultCompletionID = try container.decodeIfPresent(
                String.self, forKey: .resultCompletionID
            ) ?? ""
        }
    }
}
