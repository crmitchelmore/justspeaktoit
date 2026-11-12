#if os(iOS)
import SpeakCore

/// What a foreground run shows on screen: the latest transcript, its word
/// count and the backend's confidence. A partial replaces the text every time
/// while the word count follows the mirror's throttle; the final transcript's
/// count is exact.
struct ForegroundShownTranscript {
    private(set) var text = ""
    private(set) var wordCount = 0
    var confidence: Double?

    /// A live partial. `words` is the count the mirror took when its throttle
    /// admitted this text, or `nil` to keep the previous count.
    mutating func show(partial text: String, words: Int?) {
        self.text = text
        if let words { wordCount = words }
    }

    mutating func show(final text: String) {
        self.text = text
        wordCount = text.split(whereSeparator: \.isWhitespace).count
    }

    /// The shown text as a result, for a stop that has no provider result.
    func result(confidence: Double?, duration: Int, model: String) -> TranscriptionResult {
        .shown(text, confidence: confidence, duration: duration, model: model)
    }
}
#endif
