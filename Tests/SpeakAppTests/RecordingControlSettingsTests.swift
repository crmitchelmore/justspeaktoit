import XCTest

@testable import SpeakApp

@MainActor
final class RecordingControlSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.justspeaktoit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEscapeCancellation_defaultsToEnabled() {
        XCTAssertTrue(AppSettings(defaults: defaults).cancelRecordingOnEscape)
    }

    func testEscapeCancellation_persistsDisabledAndEnabledChoices() {
        let settings = AppSettings(defaults: defaults)
        settings.cancelRecordingOnEscape = false
        XCTAssertFalse(AppSettings(defaults: defaults).cancelRecordingOnEscape)

        settings.cancelRecordingOnEscape = true
        XCTAssertTrue(AppSettings(defaults: defaults).cancelRecordingOnEscape)
    }

    func testEscapeCancellation_reloadsImportedPreference() {
        let settings = AppSettings(defaults: defaults)
        defaults.set(false, forKey: AppSettings.DefaultsKey.cancelRecordingOnEscape.rawValue)

        settings.reloadAfterMigration()

        XCTAssertFalse(settings.cancelRecordingOnEscape)
    }

    func testNavigationUpgrade_migratesPreviousShippedDefaultsAndPersistsThem() throws {
        let previous: [ShortcutAction: KeyBinding] = [
            .openCompareModelsSettings: KeyBinding(keyCode: 0, modifiers: [], isGlobal: false, isEnabled: false),
            .openDataMigrationSettings: KeyBinding(keyCode: 0, modifiers: [], isGlobal: false, isEnabled: false),
            .openAboutSettings: KeyBinding(keyCode: 25, modifiers: [.command], isGlobal: false),
            .openProfilesSettings: KeyBinding(keyCode: 29, modifiers: [.command], isGlobal: false)
        ]
        try store(previous)

        let manager = makeShortcutManager()
        let persisted = try JSONDecoder().decode(
            [ShortcutAction: KeyBinding].self,
            from: XCTUnwrap(defaults.data(forKey: "customShortcutBindings"))
        )

        for action in previous.keys {
            XCTAssertEqual(manager.binding(for: action), action.defaultKeyBinding)
            XCTAssertEqual(persisted[action], action.defaultKeyBinding)
        }
    }

    func testNavigationUpgrade_preservesCustomAndExplicitlyDisabledBindings() throws {
        let chosen: [ShortcutAction: KeyBinding] = [
            .openCompareModelsSettings: KeyBinding(keyCode: 8, modifiers: [.command, .option], isGlobal: false),
            .openDataMigrationSettings: KeyBinding(keyCode: 2, modifiers: [.command, .option], isGlobal: false),
            .openAboutSettings: KeyBinding(keyCode: 25, modifiers: [.command], isGlobal: false, isEnabled: false),
            .openProfilesSettings: KeyBinding(keyCode: 29, modifiers: [.command], isGlobal: false, isEnabled: false)
        ]
        try store(chosen)

        let manager = makeShortcutManager()

        for (action, binding) in chosen {
            XCTAssertEqual(manager.binding(for: action), binding)
        }
    }

    private func makeShortcutManager() -> ShortcutManager {
        ShortcutManager(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
            defaults: defaults
        )
    }

    private func store(_ bindings: [ShortcutAction: KeyBinding]) throws {
        defaults.set(try JSONEncoder().encode(bindings), forKey: "customShortcutBindings")
    }
}
