import Foundation

/// Shared entry mutations. The renderer remains the single authority for TTS matching.
public enum PronunciationDictionary {
    public static func adding(_ entry: PronunciationEntry, to entries: [PronunciationEntry]) -> [PronunciationEntry] {
        guard !entries.contains(where: { $0.word.lowercased() == entry.word.lowercased() }) else { return entries }
        return entries + [entry]
    }

    public static func updating(
        _ entry: PronunciationEntry, in entries: [PronunciationEntry]
    ) -> [PronunciationEntry] {
        entries.map { $0.id == entry.id ? entry : $0 }
    }

    public static func importing(
        _ imported: [PronunciationEntry], into entries: [PronunciationEntry], merge: Bool
    ) -> [PronunciationEntry] {
        guard merge else { return imported }
        return imported.reduce(entries) { adding($1, to: $0) }
    }

    public static func validate(_ entries: [PronunciationEntry]) throws {
        var ids = Set<UUID>()
        var words = Set<String>()
        for entry in entries {
            guard ids.insert(entry.id).inserted, words.insert(entry.word.lowercased()).inserted else {
                throw PronunciationDictionaryError.duplicate
            }
            guard !entry.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PronunciationDictionaryError.empty
            }
            if entry.isRegex {
                _ = try NSRegularExpression(
                    pattern: entry.word, options: entry.caseSensitive ? [] : [.caseInsensitive]
                )
            }
        }
    }
}

public enum PronunciationDictionaryError: LocalizedError {
    case duplicate, empty
    public var errorDescription: String? {
        switch self {
        case .duplicate: return "A pronunciation with this word or identity already exists."
        case .empty: return "Provide both a word and its pronunciation."
        }
    }
}

/// Device-local durable dictionary. Corrupt records are reported and never replaced by defaults.
public actor PronunciationStore {
    private let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("pronunciation.json") }

    public func load() throws -> [PronunciationEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return PronunciationEntry.defaultEntries }
        let entries = try JSONDecoder().decode([PronunciationEntry].self, from: Data(contentsOf: file))
        try PronunciationDictionary.validate(entries)
        return entries
    }

    public func save(_ entries: [PronunciationEntry]) throws {
        try PronunciationDictionary.validate(entries)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
