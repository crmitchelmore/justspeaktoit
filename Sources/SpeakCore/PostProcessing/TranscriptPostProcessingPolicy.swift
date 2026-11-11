import Foundation

/// Pure transcript rules shared by native hosts. Rules never invoke a model and
/// do not interpret custom prompts; prompt-capable cleanup is a separate mode.
public enum TranscriptPostProcessingPolicy {
    public static func processLocally(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var cleaned = trimmed.replacingOccurrences(
            of: blankAudioMarkerPattern,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"([,.;:!?])([^\s\]\)"'])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let first = cleaned.first else { return cleaned }
        let firstString = String(first)
        let capitalizedFirst = firstString.uppercased()
        if firstString != capitalizedFirst {
            cleaned.replaceSubrange(cleaned.startIndex...cleaned.startIndex, with: capitalizedFirst)
        }
        return cleaned
    }

    public static func isEffectivelyEmptyTranscript(_ text: String) -> Bool {
        let withoutBlankAudioMarkers = text.replacingOccurrences(
            of: blankAudioMarkerPattern,
            with: " ",
            options: .regularExpression
        )
        return withoutBlankAudioMarkers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let blankAudioMarkerPattern = #"(?i)\s*\[blank_audio\]\s*"#
}
