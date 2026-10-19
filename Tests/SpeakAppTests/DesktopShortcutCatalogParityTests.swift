import AppKit
import SpeakCore
import XCTest

@testable import SpeakApp

/// The shared desktop catalogue must describe exactly the Mac's shortcut actions,
/// so a binding exported on one platform means the same action on the other.
final class DesktopShortcutCatalogParityTests: XCTestCase {
    func testIdentifiersAndOrder_matchTheMac() {
        XCTAssertEqual(DesktopShortcutAction.allCases.map(\.rawValue), ShortcutAction.allCases.map(\.rawValue))
    }

    func testTitlesDefaultsAndMigrations_matchTheMac() throws {
        for action in ShortcutAction.allCases {
            let shared = try XCTUnwrap(DesktopShortcutAction(rawValue: action.rawValue))
            XCTAssertEqual(shared.displayName, action.displayName, action.rawValue)
            XCTAssertEqual(shared.supportsGlobalShortcut, action.supportsGlobalShortcut, action.rawValue)
            XCTAssertEqual(shared.isGlobalByDefault, action.isGlobalByDefault, action.rawValue)
            XCTAssertEqual(shared.defaultBinding, portable(action.defaultKeyBinding), action.rawValue)
            XCTAssertEqual(shared.legacyDefaultBindings, action.legacyDefaultKeyBindings.map(portable),
                           action.rawValue)
        }
    }

    func testMacEncodedBindings_decodeIntoTheSharedModel() throws {
        var mac: [ShortcutAction: KeyBinding] = [:]
        for action in ShortcutAction.allCases { mac[action] = action.defaultKeyBinding }
        mac[.showHistory] = KeyBinding(keyCode: 4, modifiers: [.command, .option], isGlobal: false)
        let value = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(mac))
        let shared = DesktopShortcutBindings(preference: value)
        for action in ShortcutAction.allCases {
            let key = try XCTUnwrap(DesktopShortcutAction(rawValue: action.rawValue))
            XCTAssertEqual(shared[key], portable(mac[action] ?? action.defaultKeyBinding), action.rawValue)
        }

        let data = try JSONEncoder().encode(shared.preferenceValue)
        let decoded = try JSONDecoder().decode([ShortcutAction: KeyBinding].self, from: data)
        XCTAssertEqual(decoded[.showHistory], mac[.showHistory])
    }

    private func portable(_ binding: KeyBinding) -> DesktopShortcutBinding {
        DesktopShortcutBinding(
            keyCode: binding.keyCode, modifiers: DesktopShortcutModifiers(rawValue: binding.modifiers.rawValue),
            isGlobal: binding.isGlobal, isEnabled: binding.isEnabled
        )
    }
}
