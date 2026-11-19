import Foundation
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// The dictionary list's category and search filter.
enum PronunciationEntryFilter {
    static func entries(
        _ entries: [PronunciationEntry],
        category: PronunciationEntry.Category?,
        searchText: String
    ) -> [PronunciationEntry] {
        var result = entries

        if let category {
            result = result.filter { $0.category == category.rawValue }
        }

        if !searchText.isEmpty {
            let lowercasedQuery = searchText.lowercased()
            result = result.filter { entry in
                entry.word.lowercased().contains(lowercasedQuery) ||
                entry.pronunciation.lowercased().contains(lowercasedQuery) ||
                (entry.replacement?.lowercased().contains(lowercasedQuery) ?? false)
            }
        }

        return result
    }
}

// MARK: - Document for Export

struct PronunciationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var entries: [PronunciationEntry]

    init(entries: [PronunciationEntry]) {
        self.entries = entries
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        entries = try JSONDecoder().decode([PronunciationEntry].self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        return FileWrapper(regularFileWithContents: data)
    }
}
