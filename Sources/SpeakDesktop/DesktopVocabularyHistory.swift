import Foundation
import SpeakCore

public enum DesktopVocabularyHistory {
    public static func details(_ summary: PersonalLexiconHistorySummary?) -> String {
        guard let summary else { return "No vocabulary correction snapshot was saved for this recording." }
        var sections: [String] = []
        if !summary.contextTags.isEmpty {
            sections.append("Context tags: " + summary.contextTags.joined(separator: ", "))
        }
        if let destination = summary.destinationApplication {
            sections.append("Destination: " + destination)
        }
        sections.append("Applied corrections (\(summary.applied.count))\n" + rows(summary.applied))
        sections.append(
            "Suggestions, not directly applied (\(summary.suggestions.count))\n" + rows(summary.suggestions)
        )
        return sections.joined(separator: "\n\n")
    }

    private static func rows(_ records: [PersonalLexiconCorrectionRecord]) -> String {
        guard !records.isEmpty else { return "None." }
        return records.map {
            "\($0.alias) -> \($0.canonical) (\($0.occurrences) occurrences, \($0.confidence.rawValue) confidence)"
                + ($0.reason.map { "\n  " + $0 } ?? "")
        }.joined(separator: "\n")
    }
}
