import Foundation
import SpeakCore

struct VoiceChooserFilter {
    enum Gender: String, CaseIterable {
        case any, female, male, neutral

        var trait: TTSVoice.VoiceTrait? {
            TTSVoice.VoiceTrait(rawValue: rawValue)
        }
    }

    struct Group: Identifiable {
        let provider: TTSProvider
        let voices: [TTSVoice]
        var id: String { provider.id }
    }

    var query = ""
    var provider: TTSProvider?
    var usableOnly = false
    var gender: Gender = .any

    func pinnedVoice(in voices: [TTSVoice], selection: String) -> TTSVoice? {
        voices.first { $0.id == selection }
    }

    static func isUsable(_ availability: ModelCredentialAvailability) -> Bool {
        if case .missing = availability { return false }
        return true
    }

    static func sortedVoices(_ voices: [TTSVoice]) -> [TTSVoice] {
        voices.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order == .orderedSame { return $0.id < $1.id }
            return order == .orderedAscending
        }
    }

    func groups(
        in voices: [TTSVoice],
        selection: String,
        availability: (TTSVoice) -> ModelCredentialAvailability
    ) -> [Group] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        let matches = voices.filter { voice in
            guard voice.id != selection else { return false }
            if let provider, voice.provider != provider { return false }
            if usableOnly && !Self.isUsable(availability(voice)) { return false }
            if let trait = gender.trait, !voice.traits.contains(trait) { return false }
            let searchable = ([voice.name, voice.provider.displayName] + voice.traits.map(\.rawValue))
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { searchable.contains($0) }
        }
        return Dictionary(grouping: matches, by: \.provider).map { provider, voices in
            Group(provider: provider, voices: Self.sortedVoices(voices))
        }.sorted { $0.provider.displayName.localizedStandardCompare($1.provider.displayName) == .orderedAscending }
    }
}
