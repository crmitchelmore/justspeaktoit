import Foundation

/// Manages the pronunciation dictionary for TTS processing.
/// Handles loading, saving, applying replacements, and import/export.
@MainActor
public final class PronunciationManager: ObservableObject {
    private static let storageKey = "pronunciationDictionary"
    private static let fileExtension = "json"

    @Published public private(set) var entries: [PronunciationEntry] = []
    @Published public private(set) var isLoading = false

    private let defaults: UserDefaults

    // Owns the replacement semantics shared with portable voice output. Every
    // compiled expression is kept for the manager's lifetime, as before.
    let renderer = PronunciationRenderer(retention: .unbounded)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadEntries()
    }

    // MARK: - Entry Management

    public func addEntry(_ entry: PronunciationEntry) {
        let updated = PronunciationDictionary.adding(entry, to: entries)
        guard updated.count != entries.count else { return }
        entries = updated
        saveEntries()
    }

    public func updateEntry(_ entry: PronunciationEntry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        entries = PronunciationDictionary.updating(entry, in: entries)
        saveEntries()
    }

    public func deleteEntry(_ entry: PronunciationEntry) {
        entries.removeAll { $0.id == entry.id }
        saveEntries()
    }

    public func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        saveEntries()
    }

    public func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        saveEntries()
    }

    // MARK: - Quick Add

    /// Quick-add a word with pronunciation, auto-detecting category.
    public func quickAdd(word: String, pronunciation: String) {
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
    public func applyReplacements(to text: String) -> String {
        renderer.applyReplacements(to: text, entries: entries)
    }

    // MARK: - SSML Support

    /// Generate SSML with phoneme tags for providers that support it.
    /// Uses IPA (International Phonetic Alphabet) when available.
    public func generateSSML(for text: String, provider: PronunciationPhonemeCapable) -> String {
        guard provider.supportsSSMLPhonemes else { return applyReplacements(to: text) }
        if VoiceSynthesisMarkup.containsAuthoredMarkup(in: text) { return text }
        return renderer.generateSSML(for: text, entries: entries, provider: provider)
    }

    // MARK: - Category Filtering

    public func entries(for category: PronunciationEntry.Category?) -> [PronunciationEntry] {
        guard let category = category else {
            return entries
        }
        return entries.filter { $0.category == category.rawValue }
    }

    public var categories: [PronunciationEntry.Category] {
        let usedCategories = Set(entries.compactMap { $0.category })
        return PronunciationEntry.Category.allCases.filter { usedCategories.contains($0.rawValue) }
    }

    // MARK: - Search

    public func search(_ query: String) -> [PronunciationEntry] {
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

    public func exportToJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    public func importFromJSON(_ data: Data, merge: Bool = true) throws {
        let decoder = JSONDecoder()
        let importedEntries = try decoder.decode([PronunciationEntry].self, from: data)

        entries = PronunciationDictionary.importing(importedEntries, into: entries, merge: merge)

        saveEntries()
    }

    public func exportToFile() throws -> URL {
        let data = try exportToJSON()
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "pronunciation_dictionary_\(ISO8601DateFormatter().string(from: Date())).\(Self.fileExtension)"
        let fileURL = tempDir.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    public func importFromFile(_ url: URL, merge: Bool = true) throws {
        let data = try Data(contentsOf: url)
        try importFromJSON(data, merge: merge)
    }

    // MARK: - Reset/Defaults

    public func resetToDefaults() {
        entries = PronunciationEntry.defaultEntries
        saveEntries()
    }

    public func addDefaultEntries() {
        for defaultEntry in PronunciationEntry.defaultEntries
        where !entries.contains(where: { $0.word.lowercased() == defaultEntry.word.lowercased() }) {
            entries.append(defaultEntry)
        }
        saveEntries()
    }

    public func clearAll() {
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

extension PronunciationManager {
    public func reloadAfterMigration() { loadEntries() }
}
