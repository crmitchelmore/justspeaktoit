import Foundation

/// A History record the palette can reveal. Hosts build these from their own
/// History store; the palette only ranks and shows them.
public struct CommandPaletteHistoryItem: Identifiable, Hashable, Sendable {
    public let id: String
    /// What the row reads as, such as the transcript's opening words.
    public let title: String
    /// Secondary text, such as when it was recorded and with which model.
    public let detail: String
    /// The text a query is matched against: transcripts, models and so on.
    public let searchText: String

    public init(id: String, title: String, detail: String, searchText: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.searchText = searchText
    }

    /// The automation identifier of the item's palette row.
    public var resultAccessibilityIdentifier: String { "commandPaletteResult.history.\(id)" }
}

/// Pure ranking for the "Search for anything" palette, shared by the Mac,
/// Windows and Linux: matching actions first, then History, then settings, so
/// each host only renders rows.
public struct CommandPaletteSearch: Sendable {
    public enum Item: Hashable, Sendable {
        case command(CommandPaletteAction)
        case setting(SettingsSearchEntry)
        case history(CommandPaletteHistoryItem)
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public let item: Item
        public let matchedKeyword: String?
        public let group: String

        public var id: String {
            switch item {
            case .command(let command): return command.id
            case .setting(let entry): return entry.id
            case .history(let record): return "history." + record.id
            }
        }
    }

    public static let commandLimit = 6
    public static let historyLimit = 5
    public static let settingLimit = 30
    public static let commandsGroup = "Actions"
    public static let historyGroup = "History"
    public static let recentHistoryGroup = "Recent History"
    public static let settingsGroup = "Settings"
    public static let recentSettingsGroup = "Recent Settings"
    public static let suggestedSettingsGroup = "Suggested Settings"

    private let commands: [CommandPaletteAction]
    private let commandsByID: [String: CommandPaletteAction]
    private let commandIndex: SettingsSearchIndex
    private let settingsIndex: SettingsSearchIndex
    private let history: [(item: CommandPaletteHistoryItem, folded: String)]

    /// `history` is newest first; an empty query lists its first items.
    public init(
        commands: [CommandPaletteAction], settings: [SettingsSearchEntry], history: [CommandPaletteHistoryItem] = []
    ) {
        self.commands = commands
        commandsByID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commandIndex = SettingsSearchIndex(entries: commands.map(\.searchEntry))
        settingsIndex = SettingsSearchIndex(entries: settings)
        self.history = history.map { ($0, Self.fold($0.searchText)) }
    }

    private init(_ search: CommandPaletteSearch, history: [CommandPaletteHistoryItem]) {
        commands = search.commands
        commandsByID = search.commandsByID
        commandIndex = search.commandIndex
        settingsIndex = search.settingsIndex
        self.history = history.map { ($0, Self.fold($0.searchText)) }
    }

    /// The same actions and settings over another History snapshot, without
    /// rebuilding the indexes.
    public func replacingHistory(_ history: [CommandPaletteHistoryItem]) -> CommandPaletteSearch {
        CommandPaletteSearch(self, history: history)
    }

    /// For an empty query: every action, recent History, then recent and
    /// suggested settings.
    public func rows(for query: String, recentSettingIDs: [String] = []) -> [Row] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let commandRows = commandIndex.search(query, limit: Self.commandLimit).compactMap { result in
                commandsByID[result.entry.id].map {
                    Row(item: .command($0), matchedKeyword: result.matchedKeyword, group: Self.commandsGroup)
                }
            }
            let historyRows = historyMatches(query).map {
                Row(item: .history($0), matchedKeyword: nil, group: Self.historyGroup)
            }
            let settingRows = settingsIndex.search(query, limit: Self.settingLimit).map {
                Row(item: .setting($0.entry), matchedKeyword: $0.matchedKeyword, group: Self.settingsGroup)
            }
            return commandRows + historyRows + settingRows
        }
        let recents = recentSettingIDs.compactMap { settingsIndex.entry(id: $0) }
        let suggested = SettingsSearchCatalog.suggestedEntryIDs
            .filter { !recentSettingIDs.contains($0) }
            .compactMap { settingsIndex.entry(id: $0) }
        return commands.map { Row(item: .command($0), matchedKeyword: nil, group: Self.commandsGroup) }
            + history.prefix(Self.historyLimit).map {
                Row(item: .history($0.item), matchedKeyword: nil, group: Self.recentHistoryGroup)
            }
            + recents.map { Row(item: .setting($0), matchedKeyword: nil, group: Self.recentSettingsGroup) }
            + suggested.map { Row(item: .setting($0), matchedKeyword: nil, group: Self.suggestedSettingsGroup) }
    }

    /// Typeahead phrases from actions and settings.
    public func completions(for query: String, limit: Int = 5) -> [String] {
        var seen = Set<String>()
        let phrases = commandIndex.completions(for: query, limit: limit)
            + settingsIndex.completions(for: query, limit: limit)
        return Array(phrases.filter { seen.insert($0.lowercased()).inserted }.prefix(limit))
    }

    /// History items containing every word of `query`, ignoring case and
    /// accents, newest first.
    private func historyMatches(_ query: String) -> [CommandPaletteHistoryItem] {
        let terms = Self.fold(query).split(separator: " ")
        guard !terms.isEmpty else { return [] }
        return history.lazy
            .filter { record in terms.allSatisfy { record.folded.contains($0) } }
            .prefix(Self.historyLimit)
            .map(\.item)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
