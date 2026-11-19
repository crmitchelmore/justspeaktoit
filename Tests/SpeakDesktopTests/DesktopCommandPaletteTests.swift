import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

/// The shared "Search for anything" model (SpeakCore's `CommandPaletteSearch`)
/// as the Windows and Linux palettes use it, over actions, History and settings.
final class DesktopCommandPaletteTests: XCTestCase {
    private static let runnable = Set(DesktopShortcutAction.allCases)

    private func history(_ texts: [String]) -> [CommandPaletteHistoryItem] {
        texts.enumerated().map { index, text in
            CommandPaletteHistoryItem(id: "id\(index)", title: text, detail: "Today", searchText: text)
        }
    }

    func testQuery_ListsActionsThenHistoryThenSettings() {
        let snapshot = CommandPaletteHistorySnapshot()
        snapshot.items = history(["History of the meeting", "Grocery list"])
        let session = DesktopCommandPaletteSession(platform: .linux, runnable: Self.runnable, history: snapshot)

        let identifiers = session.results(for: "history").map(\.identifier)

        let kinds = identifiers.map { identifier -> Int in
            if identifier.hasPrefix("commandPaletteResult.command.") { return 0 }
            return identifier.hasPrefix("commandPaletteResult.history.") ? 1 : 2
        }
        XCTAssertEqual(identifiers.first, "commandPaletteResult.command.showHistory")
        XCTAssertEqual(kinds, kinds.sorted())
        XCTAssertTrue(identifiers.contains("commandPaletteResult.history.id0"))
        XCTAssertFalse(identifiers.contains("commandPaletteResult.history.id1"))
    }

    func testEmptyQuery_ListsActionsRecentHistoryThenSuggestedSettings() {
        let search = CommandPaletteSearch(
            commands: CommandPaletteAction.runnable(Self.runnable),
            settings: DesktopSettingsSearch.entries(for: .windows),
            history: history((1...8).map { "Note \($0)" })
        )

        let groups = search.rows(for: "  ").map(\.group)

        let actions = CommandPaletteAction.runnable(Self.runnable).count
        XCTAssertEqual(
            Array(groups.prefix(actions)), Array(repeating: CommandPaletteSearch.commandsGroup, count: actions)
        )
        XCTAssertEqual(
            Array(groups.dropFirst(actions).prefix(CommandPaletteSearch.historyLimit)),
            Array(repeating: CommandPaletteSearch.recentHistoryGroup, count: CommandPaletteSearch.historyLimit)
        )
        XCTAssertEqual(groups.last, CommandPaletteSearch.suggestedSettingsGroup)
    }

    func testHistoryMatch_IgnoresCaseAndAccentsAndNeedsEveryWord() {
        let search = CommandPaletteSearch(
            commands: [], settings: [],
            history: history(["Café meeting notes", "Meeting about the cafe budget", "Lunch notes"])
        )

        XCTAssertEqual(search.rows(for: "CAFE meeting").map(\.id), ["history.id0", "history.id1"])
        XCTAssertEqual(search.rows(for: "lunch café").map(\.id), [])
        XCTAssertEqual(search.rows(for: "notes").map(\.group), ["History", "History"])
    }

    func testHistoryMatches_AreCappedNewestFirst() {
        let search = CommandPaletteSearch(
            commands: [], settings: [], history: history((0..<9).map { "draft \($0)" })
        )

        XCTAssertEqual(
            search.rows(for: "draft").map(\.id), (0..<CommandPaletteSearch.historyLimit).map { "history.id\($0)" }
        )
    }

    func testRunnable_KeepsOnlyHostActionsAndNeverThePaletteOrCopyLastTranscript() {
        let session = DesktopCommandPaletteSession(
            platform: .windows, runnable: [.startStopRecording, .showHistory, .openCommandPalette]
        )

        let actions = session.results(for: "").map(\.identifier)
            .filter { $0.hasPrefix("commandPaletteResult.command.") }

        XCTAssertEqual(
            actions, ["commandPaletteResult.command.startStopRecording", "commandPaletteResult.command.showHistory"]
        )
    }

    func testChoose_ReturnsEachKindsTargetAndRemembersSettings() throws {
        let snapshot = CommandPaletteHistorySnapshot()
        snapshot.items = history(["Launch plan"])
        let session = DesktopCommandPaletteSession(platform: .linux, runnable: Self.runnable, history: snapshot)

        let rows = session.results(for: "launch")
        let historyRow = try XCTUnwrap(rows.firstIndex { $0.identifier == "commandPaletteResult.history.id0" })
        XCTAssertEqual(session.choose(historyRow), .history("id0"))
        let settingRow = try XCTUnwrap(rows.firstIndex { $0.identifier.hasPrefix("settingsSearchResult.") })
        guard case .setting(let target) = session.choose(settingRow) else { return XCTFail("Not a setting") }
        XCTAssertNil(session.choose(rows.count))

        let recent = session.results(for: "")
        let action = try XCTUnwrap(recent.firstIndex { $0.identifier == "commandPaletteResult.command.showHistory" })
        XCTAssertEqual(session.choose(action), .action(.showHistory))
        let remembered = try XCTUnwrap(recent.firstIndex { $0.identifier == rows[settingRow].identifier })
        XCTAssertEqual(session.choose(remembered), .setting(target))
    }

    func testRows_DescribeTheirKindForScreenReadersAndStayWithinNativeLimits() {
        let snapshot = CommandPaletteHistorySnapshot()
        snapshot.items = [
            CommandPaletteHistoryItem(
                id: "long", title: String(repeating: "é", count: 400), detail: "Yesterday", searchText: "long"
            )
        ]
        let session = DesktopCommandPaletteSession(platform: .windows, runnable: Self.runnable, history: snapshot)

        let rows = session.results(for: "")

        XCTAssertTrue(rows.first?.detail.hasPrefix("Action · ") == true)
        let history = rows.first { $0.identifier == "commandPaletteResult.history.long" }
        XCTAssertEqual(history?.detail, "History · Yesterday")
        XCTAssertLessThanOrEqual(history?.title.utf8.count ?? .max, 256)
        XCTAssertTrue(history?.title.hasSuffix("…") == true)
        XCTAssertLessThanOrEqual(session.results(for: "e").count, DesktopCommandPaletteSession.maximumRows)
    }

    func testSnapshot_KeepsTheNewestFiftyRecords() {
        let start = Date(timeIntervalSince1970: 1_000)
        let records = (0..<60).map { offset in
            DesktopRecordingStore.Record(
                id: UUID(), audioFilename: "\(offset).wav", modelIdentifier: "test",
                createdAt: start.addingTimeInterval(TimeInterval(offset))
            )
        }
        let snapshot = CommandPaletteHistorySnapshot()

        snapshot.items = CommandPaletteHistoryItem.newest(records, limit: 100) { _ in "" }

        XCTAssertEqual(snapshot.items.count, CommandPaletteHistorySnapshot.limit)
        XCTAssertEqual(snapshot.items.first?.id, records.last?.id.uuidString)
    }
}
