import Foundation

/// A ranked search hit.
public struct SettingsSearchResult: Hashable, Sendable {
    public let entry: SettingsSearchEntry
    public let score: Int
    /// The phrase that matched when the title did not, so hosts can explain the hit
    /// (for example "Matches “keep audio”").
    public let matchedKeyword: String?
}

/// Fast in-memory search over settings entries. Build once per catalogue and
/// platform; every query is a linear scan of a few hundred short strings.
public struct SettingsSearchIndex: Sendable {
    private struct Document: Sendable {
        let entry: SettingsSearchEntry
        let title: String
        let titleWords: [String]
        let keywords: [Phrase]
        let sectionWords: [String]
        let summaryWords: [String]
        let settingKeys: [String]
    }

    private struct Phrase: Sendable {
        let original: String
        let normalized: String
        let words: [String]
    }

    private struct TokenMatch {
        var score: Int
        var keyword: String?
        var hitTitle: Bool
    }

    private let documents: [Document]
    private let documentsByID: [String: Document]

    public init(entries: [SettingsSearchEntry]) {
        let documents = entries.map { entry in
            Document(
                entry: entry,
                title: Self.normalize(entry.title),
                titleWords: Self.words(entry.title),
                keywords: entry.keywords.map {
                    Phrase(original: $0, normalized: Self.normalize($0), words: Self.words($0))
                },
                sectionWords: Self.words(entry.section.title),
                summaryWords: Self.words(entry.summary),
                settingKeys: entry.settingKeys.map { $0.lowercased() }
            )
        }
        self.documents = documents
        self.documentsByID = Dictionary(documents.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var entries: [SettingsSearchEntry] { documents.map(\.entry) }

    public func entry(id: String) -> SettingsSearchEntry? { documentsByID[id]?.entry }

    /// Ranked results. Every query word must match the entry's title, keywords,
    /// page, summary or setting name, directly, through a synonym or with a typo.
    public func search(_ query: String, limit: Int = 25) -> [SettingsSearchResult] {
        let normalizedQuery = Self.normalize(query)
        let allTokens = normalizedQuery.split(separator: " ").map(String.init)
        let meaningful = allTokens.filter { !Self.stopWords.contains($0) }
        let tokens = meaningful.isEmpty ? allTokens : meaningful
        guard !tokens.isEmpty else { return [] }

        var results: [SettingsSearchResult] = []
        for document in documents {
            guard let result = score(document, query: normalizedQuery, tokens: tokens) else { continue }
            results.append(result)
        }
        results.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.entry.title < $1.entry.title
        }
        return Array(results.prefix(limit))
    }

    /// Typeahead phrases (titles and keywords) that extend what has been typed.
    public func completions(for query: String, limit: Int = 6) -> [String] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        var seen = Set<String>()
        var ranked: [(phrase: String, rank: Int)] = []
        func consider(_ phrase: String, normalized: String, isTitle: Bool) {
            guard normalized != normalizedQuery, !seen.contains(normalized) else { return }
            let rank: Int
            if normalized.hasPrefix(normalizedQuery) {
                rank = isTitle ? 0 : 1
            } else if normalized.contains(" " + normalizedQuery) {
                rank = isTitle ? 2 : 3
            } else {
                return
            }
            seen.insert(normalized)
            ranked.append((phrase, rank * 1_000 + normalized.count))
        }
        for document in documents {
            consider(document.entry.title, normalized: document.title, isTitle: true)
            for keyword in document.keywords {
                consider(keyword.original, normalized: keyword.normalized, isTitle: false)
            }
        }
        return ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.phrase < $1.phrase }
            .prefix(limit)
            .map(\.phrase)
    }

    private func score(_ document: Document, query: String, tokens: [String]) -> SettingsSearchResult? {
        var total = 0
        var keyword: String?
        var titleHits = 0
        for token in tokens {
            guard let match = bestMatch(for: token, in: document) else { return nil }
            total += match.score
            if match.hitTitle { titleHits += 1 }
            if keyword == nil { keyword = match.keyword }
        }

        if document.title == query {
            total += 300
        } else if document.title.hasPrefix(query) {
            total += 150
        }
        if let phrase = document.keywords.first(where: { $0.normalized == query }) {
            total += 120
            keyword = phrase.original
        } else if let phrase = document.keywords.first(where: { $0.normalized.hasPrefix(query) }) {
            total += 60
            keyword = keyword ?? phrase.original
        }
        if document.entry.isSectionRoot { total -= 5 }
        return SettingsSearchResult(
            entry: document.entry,
            score: total,
            matchedKeyword: titleHits == tokens.count ? nil : keyword
        )
    }

    private func bestMatch(for token: String, in document: Document) -> TokenMatch? {
        var best = directMatch(for: token, in: document)
        for synonym in SettingsSearchSynonyms.alternatives(for: token) {
            guard var match = directMatch(for: synonym, in: document) else { continue }
            match.score = match.score * 4 / 5
            if match.score > (best?.score ?? 0) { best = match }
        }
        return best
    }

    // Weighted so a title hit always outranks a keyword hit of the same kind.
    // swiftlint:disable:next cyclomatic_complexity
    private func directMatch(for token: String, in document: Document) -> TokenMatch? {
        var best: TokenMatch?
        func offer(_ score: Int, keyword: String? = nil, hitTitle: Bool = false) {
            if score > (best?.score ?? 0) { best = TokenMatch(score: score, keyword: keyword, hitTitle: hitTitle) }
        }
        let allowsInfix = token.count >= 3
        for word in document.titleWords {
            if word == token {
                offer(100, hitTitle: true)
            } else if word.hasPrefix(token) {
                offer(80, hitTitle: true)
            } else if Self.extends(token, word) {
                offer(60, hitTitle: true)
            }
        }
        if allowsInfix, document.title.contains(token) { offer(40, hitTitle: true) }
        for keyword in document.keywords {
            for word in keyword.words {
                if word == token {
                    offer(70, keyword: keyword.original)
                } else if word.hasPrefix(token) {
                    offer(55, keyword: keyword.original)
                } else if Self.extends(token, word) {
                    offer(45, keyword: keyword.original)
                }
            }
            if allowsInfix, keyword.normalized.contains(token) { offer(25, keyword: keyword.original) }
        }
        if document.sectionWords.contains(where: { $0.hasPrefix(token) }) { offer(30) }
        if document.summaryWords.contains(where: { $0.hasPrefix(token) }) { offer(20) }
        if token.count >= 4, document.settingKeys.contains(where: { $0.contains(token) }) { offer(15) }
        if best == nil, token.count >= 4 {
            let tolerance = token.count >= 8 ? 2 : 1
            if document.titleWords.contains(where: { Self.isWithin(tolerance, token, $0) }) {
                offer(12, hitTitle: true)
            } else if let keyword = document.keywords.first(where: { phrase in
                phrase.words.contains { Self.isWithin(tolerance, token, $0) }
            }) {
                offer(10, keyword: keyword.original)
            }
        }
        return best
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "the", "to", "of", "for", "in", "on", "is", "my", "i", "when", "with", "how", "do", "it"
    ]

    /// Whether `token` is an inflection of `word`, such as "cancelled" for "cancel".
    private static func extends(_ token: String, _ word: String) -> Bool {
        word.count >= 4 && token.count - word.count <= 4 && token.hasPrefix(word)
    }

    /// Lower-cased words with punctuation treated as separators.
    public static func normalize(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Whether two words are within `tolerance` edits (Levenshtein distance).
    static func isWithin(_ tolerance: Int, _ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= tolerance else { return false }
        var previous = Array(0...right.count)
        for (row, leftCharacter) in left.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: right.count)
            var rowMinimum = current[0]
            for (column, rightCharacter) in right.enumerated() {
                let substitution = previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                current[column + 1] = min(substitution, previous[column + 1] + 1, current[column] + 1)
                rowMinimum = min(rowMinimum, current[column + 1])
            }
            if rowMinimum > tolerance { return false }
            previous = current
        }
        return previous[right.count] <= tolerance
    }
}

/// Words people use interchangeably when looking for a setting.
enum SettingsSearchSynonyms {
    static let groups: [[String]] = [
        ["cancel", "discard", "abort", "escape", "esc"],
        ["delete", "remove", "erase", "clear", "purge"],
        ["keep", "save", "retain", "store", "preserve"],
        ["shortcut", "hotkey", "keybinding", "chord", "trigger"],
        ["microphone", "mic", "input"],
        ["theme", "appearance", "dark", "light"],
        ["colour", "color"],
        ["behaviour", "behavior"],
        ["tts", "voice", "speak"],
        ["stt", "transcription", "transcribe", "dictation", "dictate"],
        ["api", "key", "token", "credential", "secret"],
        ["polish", "cleanup", "rewrite", "postprocessing"],
        ["sound", "chime", "beep"],
        ["silence", "quiet"],
        ["login", "startup", "launch", "boot"],
        ["update", "upgrade"],
        ["sync", "icloud", "cloud"],
        ["analytics", "telemetry", "tracking"],
        ["hud", "overlay", "indicator"],
        ["paste", "insert", "output", "type"],
        ["language", "locale"],
        ["offline", "local", "device"],
        ["streaming", "live", "realtime"],
        ["model", "engine", "provider"],
        ["llm", "gpt", "openrouter"],
        ["vocabulary", "keyterms", "keywords", "jargon", "terms"]
    ]

    private static let lookup: [String: [String]] = {
        var lookup: [String: [String]] = [:]
        for group in groups {
            for word in group {
                lookup[word, default: []] += group.filter { $0 != word }
            }
        }
        return lookup
    }()

    static func alternatives(for token: String) -> [String] { lookup[token] ?? [] }
}

/// Most-recently-opened entry identifiers, newest first.
public enum SettingsSearchRecents {
    public static let defaultLimit = 6

    public static func recording(_ id: String, in recents: [String], limit: Int = defaultLimit) -> [String] {
        Array(([id] + recents.filter { $0 != id }).prefix(limit))
    }

    /// Encodes recents for a single string preference (newline separated).
    public static func encode(_ recents: [String]) -> String { recents.joined(separator: "\n") }

    public static func decode(_ stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init)
    }
}
