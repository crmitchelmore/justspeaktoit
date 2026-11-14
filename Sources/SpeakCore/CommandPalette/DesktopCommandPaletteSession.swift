import Foundation

/// Where a chosen desktop palette row goes.
public enum DesktopCommandPaletteTarget: Equatable, Sendable {
    /// Open the page, and reveal the preference field if there is one.
    case setting(DesktopSettingsSearchTarget)
    /// Run the action as its shortcut would.
    case action(DesktopShortcutAction)
    /// Show History with this record (`DesktopHistoryRecord.id`) selected.
    case history(String)
}

/// The latest History rows the palette may offer, newest first. The host's
/// History refresh writes it; the native UI thread reads it while searching,
/// so neither waits for the other.
public final class CommandPaletteHistorySnapshot: @unchecked Sendable {
    /// How many of the newest records the palette searches.
    public static let limit = 50

    private let lock = NSLock()
    private var stored: [CommandPaletteHistoryItem] = []

    public init() {}

    public var items: [CommandPaletteHistoryItem] {
        get { lock.withLock { stored } }
        set {
            let bounded = Array(newValue.prefix(Self.limit))
            lock.withLock { stored = bounded }
        }
    }
}

/// One Windows or Linux window's "Search for anything" palette: the shared
/// `CommandPaletteSearch` over the actions the host can run, its settings and
/// its recent History, projected onto the native settings search rows.
/// Hosts call `results(for:)` as the query changes and `choose(_:)` with a row.
public final class DesktopCommandPaletteSession {
    public typealias Row = DesktopSettingsSearchSession.Row

    /// The native lists accept at most 50 rows.
    public static let maximumRows = 50
    static let maximumTitleBytes = 256
    static let maximumDetailBytes = 1024

    private var search: CommandPaletteSearch
    private let history: CommandPaletteHistorySnapshot
    private var shown: [CommandPaletteSearch.Item] = []
    private var recents: [String] = []

    /// `runnable` is the shortcut actions this host can run from the palette.
    public init(
        platform: SettingsSearchPlatforms, runnable: Set<DesktopShortcutAction>,
        history: CommandPaletteHistorySnapshot = CommandPaletteHistorySnapshot()
    ) {
        search = CommandPaletteSearch(
            commands: CommandPaletteAction.runnable(runnable.subtracting([.openCommandPalette])),
            settings: DesktopSettingsSearch.entries(for: platform)
        )
        self.history = history
    }

    /// Ranked rows for `query`. An empty query offers every action, recent
    /// History and recent then suggested settings.
    public func results(for query: String) -> [Row] {
        search = search.replacingHistory(history.items)
        let rows = search.rows(for: query, recentSettingIDs: recents).prefix(Self.maximumRows)
        shown = rows.map(\.item)
        return rows.map(Self.row)
    }

    /// Typeahead phrases that extend `query`.
    public func completions(for query: String) -> [String] {
        search.completions(for: query)
    }

    /// The target for a row from the last `results(for:)` call. A chosen
    /// setting is recorded as recent.
    public func choose(_ row: Int) -> DesktopCommandPaletteTarget? {
        guard shown.indices.contains(row) else { return nil }
        switch shown[row] {
        case .setting(let entry):
            recents = SettingsSearchRecents.recording(entry.id, in: recents)
            return .setting(DesktopSettingsSearch.target(for: entry))
        case .command(let command):
            return command.shortcut.map(DesktopCommandPaletteTarget.action)
        case .history(let record):
            return .history(record.id)
        }
    }

    private static func row(_ row: CommandPaletteSearch.Row) -> Row {
        let title: String, detail: String, identifier: String
        switch row.item {
        case .command(let command):
            title = command.title
            detail = describe("Action", keyword: row.matchedKeyword, summary: command.summary)
            identifier = command.resultAccessibilityIdentifier
        case .setting(let entry):
            title = entry.title
            let page = entry.isSectionRoot ? "Settings page" : entry.section.title
            detail = describe(page, keyword: row.matchedKeyword, summary: entry.summary)
            identifier = entry.resultAccessibilityIdentifier
        case .history(let record):
            title = record.title
            detail = record.detail.isEmpty ? "History" : "History · \(record.detail)"
            identifier = record.resultAccessibilityIdentifier
        }
        return Row(
            title: bounded(title, bytes: maximumTitleBytes),
            detail: bounded(detail, bytes: maximumDetailBytes),
            identifier: identifier
        )
    }

    private static func describe(_ kind: String, keyword: String?, summary: String) -> String {
        keyword.map { "\(kind) · Matches “\($0)”" } ?? "\(kind) · \(summary)"
    }

    /// `text` cut on a character boundary to at most `bytes` UTF-8 bytes.
    static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            if used + size > bytes - 3 { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }
}
