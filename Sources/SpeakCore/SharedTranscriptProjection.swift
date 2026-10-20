import Foundation

/// Folds one provider event into a controller transcript. An authoritative
/// snapshot replaces the text, including explicit empty retractions.
public enum SharedTranscriptProjection {
    public static func apply(
        eventText: String,
        isFinal: Bool,
        snapshot: StreamingTranscriptSnapshot?,
        accumulator: inout TranscriptAccumulator
    ) -> String? {
        if let authoritative = snapshot?.resolvedDisplayText {
            let text = authoritative.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulator.replace(with: text)
            return text
        }
        let text = eventText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return isFinal ? accumulator.append(final: text) : accumulator.display(withInterim: text)
    }
}
