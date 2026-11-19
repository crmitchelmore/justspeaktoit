import SpeakCore
import XCTest

@testable import SpeakApp

final class CommandPaletteSearchTests: XCTestCase {
    private let search = CommandPaletteSearch(
        commands: CommandPaletteCommand.all(in: .direct), settings: MacSettingsSearch.catalogEntries
    )

    private func commandIDs(_ query: String) -> [String] {
        search.rows(for: query).compactMap {
            if case .command(let command) = $0.item { return command.id }
            return nil
        }
    }

    func testTranscribe_ranksStartStopRecordingFirst() {
        XCTAssertEqual(commandIDs("transcribe").first, "command.startStopRecording")
    }

    func testSay_offersSpeechActions() {
        let ids = commandIDs("say")
        XCTAssertTrue(ids.contains("command.speakClipboard"))
        XCTAssertTrue(ids.contains("command.openVoiceOutput"))
    }

    func testQuery_listsActionsBeforeSettings() {
        let rows = search.rows(for: "voice")
        let firstSetting = rows.firstIndex { if case .setting = $0.item { return true }; return false }
        let lastCommand = rows.lastIndex { if case .command = $0.item { return true }; return false }
        XCTAssertNotNil(firstSetting)
        XCTAssertNotNil(lastCommand)
        if let firstSetting, let lastCommand { XCTAssertLessThan(lastCommand, firstSetting) }
        XCTAssertLessThanOrEqual(rows.filter { $0.group == CommandPaletteSearch.commandsGroup }.count,
                                 CommandPaletteSearch.commandLimit)
    }

    func testSettingQuery_stillFindsSettings() {
        let rows = search.rows(for: "api keys")
        XCTAssertTrue(rows.contains {
            if case .setting(let entry) = $0.item { return entry.id == "apiKeys" }
            return false
        })
    }

    func testEmptyQuery_showsEveryActionThenSuggestedSettings() {
        let rows = search.rows(for: "  ")
        let commands = CommandPaletteCommand.all(in: .direct)
        XCTAssertEqual(rows.prefix(commands.count).map(\.id), commands.map(\.id))
        XCTAssertTrue(rows.dropFirst(commands.count).allSatisfy { $0.group == "Suggested Settings" })
    }

    func testShortcutCommands_runOnlyAvailableActionsAndNeverReopenThePalette() {
        for channel in [DistributionChannel.direct, .appStore] {
            for command in CommandPaletteCommand.all(in: channel) {
                guard let action = command.shortcutAction else { continue }
                XCTAssertTrue(action.isAvailable(in: channel), command.id)
                XCTAssertNotEqual(action, .openCommandPalette)
            }
        }
        XCTAssertEqual(Set(CommandPaletteCommand.all(in: .direct).map(\.id)).count,
                       CommandPaletteCommand.all(in: .direct).count)
    }

    func testOpenCommandPalette_defaultsToCommandKAndMovesCorrections() {
        let palette = ShortcutAction.openCommandPalette.defaultKeyBinding
        XCTAssertEqual(palette.displayString, "⌘K")
        XCTAssertFalse(palette.isGlobal)
        XCTAssertFalse(ShortcutAction.openCommandPalette.supportsGlobalShortcut)
        XCTAssertTrue(ShortcutAction.openCorrections.legacyDefaultKeyBindings.contains(palette))
    }

    @MainActor
    func testStoredCommandKCorrections_migratesSoThePaletteOwnsCommandK() throws {
        let suite = "CommandPaletteSearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: [ShortcutAction: KeyBinding] = [:]
        for action in ShortcutAction.allCases where action != .openCommandPalette {
            stored[action] = action.defaultKeyBinding
        }
        stored[.openCorrections] = KeyBinding(keyCode: 40, modifiers: [.command], isGlobal: false)
        defaults.set(try JSONEncoder().encode(stored), forKey: "customShortcutBindings")

        let manager = ShortcutManager(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }), defaults: defaults
        )

        XCTAssertEqual(manager.binding(for: .openCorrections).displayString, "⇧⌘K")
        XCTAssertEqual(manager.binding(for: .openCommandPalette).displayString, "⌘K")
        let commandK = manager.binding(for: .openCommandPalette)
        let owners = ShortcutAction.allCases.filter {
            let binding = manager.binding(for: $0)
            return binding.keyCode == commandK.keyCode && binding.modifiers == commandK.modifiers
        }
        XCTAssertEqual(owners, [.openCommandPalette])
    }
}
