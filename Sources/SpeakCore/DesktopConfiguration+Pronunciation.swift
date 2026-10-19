import Foundation

extension DesktopConfiguration {
    public static var pronunciationPreferenceKeys: Set<String> {
        [
            ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue,
            ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        ]
    }

    func pronunciationKeyterms(addingTo current: [String]) -> [String] {
        guard values[ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue] != nil else { return current }
        return AssemblyAIPronunciationKeyterms.merged(
            current: current,
            seeds: AssemblyAIPronunciationKeyterms.seeds(modern: [], legacy: legacyPronunciationWords),
            ignored: ignoredPronunciationWords
        )
    }

    func recordingPronunciationKeytermSelection(from previous: Self) throws -> Self {
        guard values[ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue] != nil,
              text("transcriptionKeywords") != previous.text("transcriptionKeywords")
                || text("assemblyAIKeyterms") != previous.text("assemblyAIKeyterms") else { return self }
        let ignored = AssemblyAIPronunciationKeyterms.ignored(
            selected: text("assemblyAIKeyterms"),
            seeds: AssemblyAIPronunciationKeyterms.seeds(modern: [], legacy: legacyPronunciationWords),
            stored: ignoredPronunciationWords
        )
        var changed = values
        changed[ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue] = AnyCodable(
            .array(ignored.map { .string($0) })
        )
        return try Self(values: changed)
    }

    static func validatePronunciationPreferences(in values: [String: AnyCodable]) throws {
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        if let value = values[dictionaryKey] {
            guard case .object(let entries) = value.storage,
                  entries.values.allSatisfy(isText) else {
                throw DesktopConfigurationError.invalidField("Legacy pronunciation dictionary (word-to-text object)")
            }
        }
        let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        if let value = values[ignoredKey] {
            guard case .array(let entries) = value.storage,
                  entries.allSatisfy(isText) else {
                throw DesktopConfigurationError.invalidField("Ignored pronunciation terms (text array)")
            }
        }
    }

    private static func isText(_ value: AnyCodable.JSONValue) -> Bool {
        if case .string = value { return true }
        return false
    }

    var legacyPronunciationWords: [String] {
        guard let value = values[ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue] else { return [] }
        guard case .object(let entries) = value.storage else {
            preconditionFailure("Invalid validated legacy pronunciation dictionary.")
        }
        return Array(entries.keys)
    }

    var ignoredPronunciationWords: [String] {
        let key = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        guard let value = values[key] else { return [] }
        guard case .array(let entries) = value.storage else {
            preconditionFailure("Invalid validated ignored pronunciation terms.")
        }
        return entries.map {
            guard case .string(let text) = $0 else {
                preconditionFailure("Invalid validated ignored pronunciation term.")
            }
            return text
        }
    }
}
