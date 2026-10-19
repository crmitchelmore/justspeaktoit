import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    func legacyPronunciationPresentation(notice: String) throws -> String {
        guard !closed else { throw CancellationError() }
        return try Self.legacyPronunciationPresentation(
            configuration().legacyPronunciationDictionary, notice: notice
        )
    }

    func legacyPronunciationEvent(_ payload: String) async throws -> String {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before changing the legacy pronunciation dictionary.")
        }
        guard payload.utf8.count <= 4 * 1024 * 1024 else { throw DesktopVocabularyError.invalidEvent }
        let fields = try DesktopVocabularyWire.decode(payload)
        guard fields.count == 4, fields[0] == "save" || fields[0] == "delete" else {
            throw DesktopVocabularyError.invalidEvent
        }
        let configuration = try configurationForNativeEditor()
        var dictionary = configuration.legacyPronunciationDictionary
        _ = try Self.legacyPronunciationPresentation(dictionary, notice: "")
        let original = try Self.legacyPronunciationOriginal(fields[1], in: dictionary)
        if fields[0] == "delete" {
            guard let original else { throw DesktopVocabularyError.unknownEntry }
            dictionary.removeValue(forKey: original)
        } else {
            let word = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let pronunciation = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !pronunciation.isEmpty else {
                throw DesktopHostError(message: "Enter both a word and its pronunciation.")
            }
            if original != word {
                guard dictionary[word] == nil else {
                    throw DesktopHostError(message: "That word already exists. Select it to change its pronunciation.")
                }
                if let original { dictionary.removeValue(forKey: original) }
            }
            dictionary[word] = pronunciation
        }
        _ = try Self.legacyPronunciationPresentation(dictionary, notice: "")
        try await persistLegacyPronunciationDictionary(dictionary, from: configuration)
        return "Legacy pronunciation dictionary saved. The modern Read aloud dictionary is unchanged."
    }

    private static func legacyPronunciationOriginal(_ identity: String, in dictionary: [String: String]) throws -> String? {
        if identity.isEmpty { return nil }
        guard let data = Data(base64Encoded: identity) else { throw DesktopVocabularyError.invalidEvent }
        let original = try JSONDecoder().decode([String].self, from: data)
        guard original.count == 2, dictionary[original[0]] == original[1] else {
            throw DesktopHostError(message: "This legacy entry changed or was removed. Reload before editing it.")
        }
        return original[0]
    }

    private static func legacyPronunciationPresentation(_ dictionary: [String: String], notice: String) throws -> String {
        let explanation = "Mac legacy word-to-pronunciation settings. Words can seed AssemblyAI."
            + " Modern Read aloud entries are separate. Use New to add a word."
        var rows = [DesktopVocabularyWire.encode([notice.isEmpty ? explanation : notice, "false", "false", ""])]
        for word in dictionary.keys.sorted() {
            guard let pronunciation = dictionary[word] else { throw DesktopVocabularyError.unknownEntry }
            guard [word, pronunciation].allSatisfy({ $0.utf8.count <= 65_535 && !$0.contains("\0") }) else {
                throw DesktopHostError(
                    message: "This legacy dictionary cannot fit safely in native fields."
                        + " Export portable preferences to preserve and edit its original values."
                )
            }
            let identity = try JSONEncoder().encode([word, pronunciation]).base64EncodedString()
            rows.append(DesktopVocabularyWire.encode([identity, word, pronunciation, "", "", "", "", ""]))
        }
        let presentation = rows.joined(separator: "\n")
        guard presentation.utf8.count <= 4 * 1024 * 1024 else {
            throw DesktopHostError(message: "This legacy dictionary is too large for the editor. Use portable preferences.")
        }
        return presentation
    }
}
