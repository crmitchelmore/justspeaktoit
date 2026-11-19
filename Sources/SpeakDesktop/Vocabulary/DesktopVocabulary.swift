import Foundation
import SpeakCore

public struct DesktopVocabularyPreferences: Codable, Sendable {
    public var includeLexiconDirectives = true
    public var includeContextTags = true
    public var contextTags: Set<String> = []
    public init() {}
}

public struct DesktopVocabularyApplication: Sendable {
    public let result: PersonalLexiconApplicationResult
    public let summary: PersonalLexiconHistorySummary
    public let directives: [String]
}

/// Native editors use escaped UTF-8 fields, not user text as commands or delimiter structure.
public enum DesktopVocabularyWire {
    public static func encode(_ fields: [String]) -> String {
        fields.map {
            $0.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "\t", with: "%09")
                .replacingOccurrences(of: "\r", with: "%0D")
                .replacingOccurrences(of: "\n", with: "%0A")
        }.joined(separator: "\t")
    }
    public static func decode(_ row: String) throws -> [String] {
        try row.components(separatedBy: "\t").map {
            guard let value = $0.removingPercentEncoding else { throw DesktopVocabularyError.invalidEvent }
            return value
        }
    }
}

public enum DesktopVocabularyError: LocalizedError, Equatable {
    case invalidEvent, unknownEntry
    public var errorDescription: String? {
        switch self {
        case .invalidEvent: return "The vocabulary editor sent an invalid action. Reopen it and try again."
        case .unknownEntry: return "This entry no longer exists. Reopen the editor."
        }
    }
}

/// One shared coordinator behind both native editors. No OS-wide text observation is performed.
@VocabularyActor
public final class DesktopVocabulary {
    private static let editorKinds: Set<Int> = [0, 1, 3]
    public let lexicon: PersonalLexiconDomain
    public let candidates: AutoCorrectionDomain
    public private(set) var entries: [PronunciationEntry] = []
    public private(set) var preferences = DesktopVocabularyPreferences()
    public private(set) var loadError: Error?
    private let pronunciation: PronunciationStore
    private let directory: URL
    private let preferencesFile: URL
    private let renderer = PronunciationRenderer(retention: .activeDictionary)
    private var operationTail: Task<Void, Never>?

    public init(directory: URL) {
        self.directory = directory
        lexicon = PersonalLexiconDomain(store: PersonalLexiconStore(appDirectory: directory))
        candidates = AutoCorrectionDomain(
            store: AutoCorrectionStore(appDirectory: directory), lexiconService: lexicon,
            promotionThreshold: { AutoCorrectionLearningPolicy.defaultPromotionThreshold }
        )
        pronunciation = PronunciationStore(directory: directory)
        preferencesFile = directory.appendingPathComponent("vocabulary.json")
    }

    public func load() async throws {
        do {
            try await loadContents()
            loadError = nil
        } catch {
            loadError = error
            throw error
        }
    }

    public func reload() async throws {
        let previous = operationTail
        let reload = Task { @VocabularyActor in
            await previous?.value
            await self.lexicon.refresh()
            await self.candidates.reloadAfterMigration()
            try await self.load()
        }
        operationTail = Task { @VocabularyActor in _ = try? await reload.value }
        try await reload.value
    }

    private func loadContents() async throws {
        await lexicon.waitUntilLoaded()
        if let error = lexicon.loadError { throw error }
        await candidates.waitUntilLoaded()
        if let error = candidates.loadError { throw error }
        entries = try await pronunciation.load()
        if FileManager.default.fileExists(atPath: preferencesFile.path) {
            preferences = try JSONDecoder().decode(
                DesktopVocabularyPreferences.self, from: Data(contentsOf: preferencesFile)
            )
        }
    }

    public func apply(_ text: String) -> DesktopVocabularyApplication {
        let context = PersonalLexiconContext(
            tags: preferences.contextTags, destinationApplication: nil, recentTranscriptWindow: text
        )
        let input = TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text) ? "" : text
        let result = lexicon.apply(to: input, context: context)
        let summary = PersonalLexiconHistorySummary(
            applied: result.applied, suggestions: result.suggestions, contextTags: context.tags.sorted()
        )
        let directives = preferences.includeLexiconDirectives
            ? PersonalLexiconDirectives.build(rules: lexicon.rules, context: context, corrections: summary) : []
        return .init(result: result, summary: summary, directives: directives)
    }

    public func keywords() -> [String] {
        PersonalLexiconDirectives.keywords(
            rules: lexicon.rules,
            context: .init(tags: preferences.contextTags, destinationApplication: nil, recentTranscriptWindow: "")
        )
    }

    public func speechText(_ text: String) -> String { renderer.applyReplacements(to: text, entries: entries) }

    public func recognitionHints() throws -> (keywords: [String], pronunciationWords: [String]) {
        if let loadError { throw loadError }
        return (keywords(), entries.filter { !$0.isRegex }.map(\.word))
    }

    public func presentation(kind: Int, notice: String = "") -> String {
        var header = [
            notice, String(preferences.includeLexiconDirectives), String(preferences.includeContextTags),
            preferences.contextTags.sorted().joined(separator: ", ")
        ]
        if kind == 1 { header += DesktopPronunciationCategories.fields(for: entries) }
        var rows = [DesktopVocabularyWire.encode(header)]
        if kind == 3 {
            rows += candidateRows()
        } else if kind == 0 {
            rows += lexicon.rules.map { rule in
                DesktopVocabularyWire.encode([
                    rule.id.uuidString, rule.displayName, rule.canonical, rule.aliases.joined(separator: "\n"),
                    rule.activation.rawValue, rule.contextTags.sorted().joined(separator: ", "),
                    rule.confidence.rawValue, rule.notes ?? ""
                ])
            }
        } else {
            rows += entries.map {
                DesktopVocabularyWire.encode([
                    $0.id.uuidString, $0.word, $0.pronunciation, $0.replacement ?? "", $0.category ?? "",
                    $0.isRegex ? "true" : "false", $0.caseSensitive ? "true" : "false", ""
                ])
            }
        }
        return rows.joined(separator: "\n")
    }

    /// An event is copied at the native callback, then awaited in event order.
    public func perform(kind: Int, payload: String) async throws -> String {
        let previous = operationTail
        let operation = Task { @VocabularyActor in
            await previous?.value
            return try await self.performImmediately(kind: kind, payload: payload)
        }
        operationTail = Task { @VocabularyActor in _ = try? await operation.value }
        return try await operation.value
    }

    private func performImmediately(kind: Int, payload: String) async throws -> String {
        if let loadError { throw loadError }
        let fields = try DesktopVocabularyWire.decode(payload)
        guard let action = fields.first, Self.editorKinds.contains(kind) else {
            throw DesktopVocabularyError.invalidEvent
        }
        if kind == 3 { return try await performCandidateAction(fields) }
        return try await performEditorAction(kind: kind, action: action, fields: fields)
    }

    private func performEditorAction(kind: Int, action: String, fields: [String]) async throws -> String {
        if action == "preview" { return try preview(kind: kind, fields: fields) }
        if action == "preferences" { return try savePreferences(fields) }
        if action == "defaults", kind == 1 {
            let changed = PronunciationDictionary.importing(
                PronunciationEntry.defaultEntries, into: entries, merge: true
            )
            try await pronunciation.save(changed)
            entries = changed
            return "Default pronunciations added."
        }
        if kind == 1, action == "importMerge" || action == "importReplace" || action == "export" {
            guard fields.count == 2 else { throw DesktopVocabularyError.invalidEvent }
            return try await transferPronunciations(action: action, file: URL(fileURLWithPath: fields[1]))
        }
        guard fields.count == 9 else { throw DesktopVocabularyError.invalidEvent }
        let id = fields[1].isEmpty ? UUID() : UUID(uuidString: fields[1])
        guard let id else { throw DesktopVocabularyError.invalidEvent }
        if kind == 0 {
            try await mutateRule(action: action, id: id, fields: fields)
        } else {
            try await mutatePronunciation(action: action, id: id, fields: fields)
        }
        return "Saved."
    }

    private static func tags(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }
}

private extension DesktopVocabulary {
    func preview(kind: Int, fields: [String]) throws -> String {
        guard fields.count == 3 else { throw DesktopVocabularyError.invalidEvent }
        if kind == 1 { return speechText(fields[1]) }
        let context = PersonalLexiconContext(
            tags: Self.tags(fields[2]), destinationApplication: "Preview", recentTranscriptWindow: fields[1]
        )
        let input = TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(fields[1]) ? "" : fields[1]
        let result = lexicon.apply(to: input, context: context)
        return result.transformedText + "\nApplied: \(result.applied.count); Suggestions: \(result.suggestions.count)"
            + result.suggestions.map { "\n\($0.alias) -> \($0.canonical): \($0.reason ?? "Suggestion")" }.joined()
    }

    func savePreferences(_ fields: [String]) throws -> String {
        guard fields.count == 4, let directives = Bool(fields[1]), let tags = Bool(fields[2]) else {
            throw DesktopVocabularyError.invalidEvent
        }
        var changed = preferences
        changed.includeLexiconDirectives = directives
        changed.includeContextTags = tags
        changed.contextTags = Self.tags(fields[3])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(changed).write(to: preferencesFile, options: .atomic)
        preferences = changed
        return "Lexicon context settings saved."
    }

    func transferPronunciations(action: String, file: URL) async throws -> String {
        if action == "export" {
            let destination = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let state = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            #if os(Linux)
            let comparison: String.CompareOptions = []
            #else
            let comparison: String.CompareOptions = .caseInsensitive
            #endif
            let withinState = destination.count >= state.count && zip(destination, state).allSatisfy {
                $0.compare($1, options: comparison) == .orderedSame
            }
            guard !withinState else { throw CocoaError(.fileWriteNoPermission) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: file, options: .atomic)
            return "Pronunciation dictionary exported."
        }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 4 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let imported = try JSONDecoder().decode([PronunciationEntry].self, from: Data(contentsOf: file))
        try PronunciationDictionary.validate(imported)
        let changed = PronunciationDictionary.importing(imported, into: entries, merge: action == "importMerge")
        try await pronunciation.save(changed)
        entries = changed
        return "Pronunciation dictionary imported."
    }

    func mutateRule(action: String, id: UUID, fields: [String]) async throws {
        switch action {
        case "delete":
            guard lexicon.rules.contains(where: { $0.id == id }) else { throw DesktopVocabularyError.unknownEntry }
            try await lexicon.deleteRule(id: id)
        case "up", "down":
            guard let index = lexicon.rules.firstIndex(where: { $0.id == id }) else {
                throw DesktopVocabularyError.unknownEntry
            }
            let destination = max(0, min(lexicon.rules.count, action == "up" ? index - 1 : index + 2))
            try await lexicon.moveRules(from: IndexSet(integer: index), to: destination)
        case "save":
            guard let activation = PersonalLexiconRule.Activation(rawValue: fields[5]),
                  let confidence = PersonalLexiconConfidence(rawValue: fields[7]) else {
                throw DesktopVocabularyError.invalidEvent
            }
            let existing = lexicon.rules.first { $0.id == id }
            guard fields[1].isEmpty || existing != nil else { throw DesktopVocabularyError.unknownEntry }
            let aliases = fields[4].components(separatedBy: .newlines)
            if let existing {
                var rule = existing
                rule.displayName = fields[2]; rule.canonical = fields[3]; rule.aliases = aliases
                rule.activation = activation; rule.contextTags = Self.tags(fields[6])
                rule.confidence = confidence; rule.notes = fields[8]
                try await lexicon.updateRule(rule)
            } else {
                _ = try await lexicon.addRule(
                    displayName: fields[2], canonical: fields[3], aliases: aliases,
                    activation: activation, contextTags: Self.tags(fields[6]),
                    confidence: confidence, notes: fields[8]
                )
            }
        default: throw DesktopVocabularyError.invalidEvent
        }
    }

    func mutatePronunciation(action: String, id: UUID, fields: [String]) async throws {
        var changed = entries
        switch action {
        case "delete":
            guard changed.contains(where: { $0.id == id }) else { throw DesktopVocabularyError.unknownEntry }
            changed.removeAll { $0.id == id }
        case "up", "down":
            guard let index = changed.firstIndex(where: { $0.id == id }) else {
                throw DesktopVocabularyError.unknownEntry
            }
            let destination = max(0, min(changed.count - 1, index + (action == "up" ? -1 : 1)))
            let entry = changed.remove(at: index)
            changed.insert(entry, at: destination)
        case "save":
            guard let regex = Bool(fields[6]), let sensitive = Bool(fields[7]) else {
                throw DesktopVocabularyError.invalidEvent
            }
            let entry = PronunciationEntry(
                id: id, word: fields[2], pronunciation: fields[3],
                replacement: fields[4].isEmpty ? nil : fields[4], category: fields[5].isEmpty ? nil : fields[5],
                isRegex: regex, caseSensitive: sensitive
            )
            guard fields[1].isEmpty || changed.contains(where: { $0.id == id }) else {
                throw DesktopVocabularyError.unknownEntry
            }
            if changed.contains(where: { $0.id == id }) {
                changed = PronunciationDictionary.updating(entry, in: changed)
            } else { changed.append(entry) }
        default: throw DesktopVocabularyError.invalidEvent
        }
        try await pronunciation.save(changed)
        entries = changed
    }
}
