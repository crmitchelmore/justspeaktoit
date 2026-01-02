import Foundation

/// Manages the pronunciation dictionary for TTS processing.
/// Handles loading, saving, applying replacements, and import/export.
@MainActor
final class PronunciationManager: ObservableObject {
    private static let storageKey = "pronunciationDictionary"
    private static let fileExtension = "json"

    @Published private(set) var entries: [PronunciationEntry] = []
    @Published private(set) var isLoading = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadEntries()
    }

    // MARK: - Entry Management

    func addEntry(_ entry: PronunciationEntry) {
        // Check for duplicates
        guard !entries.contains(where: { $0.word.lowercased() == entry.word.lowercased() }) else {
            return
        }
        entries.append(entry)
        saveEntries()
    }

    func updateEntry(_ entry: PronunciationEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            saveEntries()
        }
    }

    func deleteEntry(_ entry: PronunciationEntry) {
        entries.removeAll { $0.id == entry.id }
        saveEntries()
    }

    func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        saveEntries()
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        saveEntries()
    }

    // MARK: - Quick Add

    /// Quick-add a word with pronunciation, auto-detecting category.
    func quickAdd(word: String, pronunciation: String) {
        let category = detectCategory(for: word)
        let entry = PronunciationEntry(
            word: word,
            pronunciation: pronunciation,
            replacement: pronunciation,
            category: category?.rawValue
        )
        addEntry(entry)
    }

    private func detectCategory(for word: String) -> PronunciationEntry.Category? {
        let upper = word.uppercased()
        if upper == word && word.count >= 2 && word.count <= 6 {
            return .acronyms
        }
        if word.first?.isSymbol == true || word.first?.isPunctuation == true {
            return .symbols
        }
        if word.first?.isUppercase == true && word.count > 1 {
            return .names
        }
        return .custom
    }

    // MARK: - Text Processing

    /// Apply pronunciation replacements to text before TTS processing.
    func applyReplacements(to text: String) -> String {
        var result = text

        for entry in entries {
            if let replacement = entry.replacement, !replacement.isEmpty {
                if entry.isRegex {
                    result = applyRegexReplacement(
                        text: result,
                        pattern: entry.word,
                        replacement: replacement,
                        caseSensitive: entry.caseSensitive
                    )
                } else {
                    result = applySimpleReplacement(
                        text: result,
                        word: entry.word,
                        replacement: replacement,
                        caseSensitive: entry.caseSensitive
                    )
                }
            }
        }

        return result
    }

    private func applySimpleReplacement(
        text: String,
        word: String,
        replacement: String,
        caseSensitive: Bool
    ) -> String {
        if caseSensitive {
            return text.replacingOccurrences(of: word, with: replacement)
        } else {
            // Case-insensitive replacement with word boundaries
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: .caseInsensitive
            ) else {
                return text
            }

            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
    }

    private func applyRegexReplacement(
        text: String,
        pattern: String,
        replacement: String,
        caseSensitive: Bool
    ) -> String {
        var options: NSRegularExpression.Options = []
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    // MARK: - SSML Support

    /// Generate SSML with phoneme tags for providers that support it.
    /// Uses IPA (International Phonetic Alphabet) when available.
    func generateSSML(for text: String, provider: TTSProvider) -> String {
        guard provider.supportsSSMLPhonemes else {
            // For providers without phoneme support, just use text replacement
            return applyReplacements(to: text)
        }

        var result = text

        for entry in entries {
            let phonemeTag = buildPhonemeTag(
                word: entry.word,
                pronunciation: entry.pronunciation,
                provider: provider
            )

            if entry.isRegex {
                // For regex entries, we can't easily apply phoneme tags
                // Fall back to simple replacement
                if let replacement = entry.replacement {
                    result = applyRegexReplacement(
                        text: result,
                        pattern: entry.word,
                        replacement: replacement,
                        caseSensitive: entry.caseSensitive
                    )
                }
            } else {
                result = applySimpleReplacement(
                    text: result,
                    word: entry.word,
                    replacement: phonemeTag,
                    caseSensitive: entry.caseSensitive
                )
            }
        }

        return result
    }

    private func buildPhonemeTag(word: String, pronunciation: String, provider: TTSProvider) -> String {
        // Different providers use different phoneme alphabets
        let alphabet = provider.phonemeAlphabet
        let escapedPronunciation = pronunciation
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return "<phoneme alphabet=\"\(alphabet)\" ph=\"\(escapedPronunciation)\">\(word)</phoneme>"
    }

    // MARK: - Category Filtering

    func entries(for category: PronunciationEntry.Category?) -> [PronunciationEntry] {
        guard let category = category else {
            return entries
        }
        return entries.filter { $0.category == category.rawValue }
    }

    var categories: [PronunciationEntry.Category] {
        let usedCategories = Set(entries.compactMap { $0.category })
        return PronunciationEntry.Category.allCases.filter { usedCategories.contains($0.rawValue) }
    }

    // MARK: - Search

    func search(_ query: String) -> [PronunciationEntry] {
        guard !query.isEmpty else { return entries }
        let lowercasedQuery = query.lowercased()
        return entries.filter { entry in
            entry.word.lowercased().contains(lowercasedQuery) ||
            entry.pronunciation.lowercased().contains(lowercasedQuery) ||
            (entry.replacement?.lowercased().contains(lowercasedQuery) ?? false) ||
            (entry.category?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }

    // MARK: - Import/Export

    func exportToJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    func importFromJSON(_ data: Data, merge: Bool = true) throws {
        let decoder = JSONDecoder()
        let importedEntries = try decoder.decode([PronunciationEntry].self, from: data)

        if merge {
            // Merge: add new entries, skip duplicates
            for entry in importedEntries {
                if !entries.contains(where: { $0.word.lowercased() == entry.word.lowercased() }) {
                    entries.append(entry)
                }
            }
        } else {
            // Replace all entries
            entries = importedEntries
        }

        saveEntries()
    }

    func exportToFile() throws -> URL {
        let data = try exportToJSON()
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "pronunciation_dictionary_\(ISO8601DateFormatter().string(from: Date())).\(Self.fileExtension)"
        let fileURL = tempDir.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    func importFromFile(_ url: URL, merge: Bool = true) throws {
        let data = try Data(contentsOf: url)
        try importFromJSON(data, merge: merge)
    }

    // MARK: - Reset/Defaults

    func resetToDefaults() {
        entries = PronunciationEntry.defaultEntries
        saveEntries()
    }

    func addDefaultEntries() {
        for defaultEntry in PronunciationEntry.defaultEntries {
            if !entries.contains(where: { $0.word.lowercased() == defaultEntry.word.lowercased() }) {
                entries.append(defaultEntry)
            }
        }
        saveEntries()
    }

    func clearAll() {
        entries = []
        saveEntries()
    }

    // MARK: - Persistence

    private func loadEntries() {
        isLoading = true
        defer { isLoading = false }

        guard let data = defaults.data(forKey: Self.storageKey) else {
            // First launch: load defaults
            entries = PronunciationEntry.defaultEntries
            saveEntries()
            return
        }

        do {
            entries = try JSONDecoder().decode([PronunciationEntry].self, from: data)
        } catch {
            // Migration or corruption: reset to defaults
            entries = PronunciationEntry.defaultEntries
            saveEntries()
        }
    }

    private func saveEntries() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            // Silent failure - entries will be reloaded on next launch
        }
    }
}

// MARK: - TTSProvider Extensions

extension TTSProvider {
    /// Whether this provider supports SSML phoneme tags.
    var supportsSSMLPhonemes: Bool {
        switch self {
        case .azure, .system: return true
        case .elevenlabs, .openai, .deepgram: return false
        }
    }

    /// The phoneme alphabet to use for SSML tags.
    var phonemeAlphabet: String {
        switch self {
        case .azure: return "ipa"
        case .system: return "ipa"
        default: return "ipa"
        }
    }
}
