import Foundation
import SpeakCore

extension DesktopVocabulary {
    func candidateRows() -> [String] {
        candidates.candidates.map {
            DesktopVocabularyWire.encode([
                $0.id.uuidString, $0.original, $0.corrected, String($0.seenCount),
                $0.sourceApps.sorted().joined(separator: ", "),
                $0.firstSeenAt.formatted(.iso8601), $0.lastSeenAt.formatted(.iso8601),
                $0.dismissed ? "Dismissed" : "Pending"
            ])
        }
    }

    func performCandidateAction(_ fields: [String]) async throws -> String {
        if fields == ["clear"] {
            try await candidates.clearAllCandidates()
            return "Stored candidates cleared. Saved correction rules are unchanged."
        }
        guard fields.count == 2, let id = UUID(uuidString: fields[1]) else {
            throw DesktopVocabularyError.invalidEvent
        }
        guard let candidate = candidates.candidates.first(where: { $0.id == id }) else {
            throw DesktopVocabularyError.unknownEntry
        }
        switch fields[0] {
        case "promote":
            try await candidates.promoteCandidate(candidate)
            return "Candidate saved as an automatic correction rule."
        case "dismiss":
            try await candidates.dismissCandidate(id: id)
            return "Candidate dismissed."
        case "remove":
            try await candidates.removeCandidate(id: id)
            return "Candidate removed."
        default:
            throw DesktopVocabularyError.invalidEvent
        }
    }
}
