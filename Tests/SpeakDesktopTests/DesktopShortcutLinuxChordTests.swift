import Foundation
import SpeakCore
import XCTest

final class DesktopShortcutLinuxChordTests: XCTestCase {
    func testCanonicalKeys_HaveUniqueLinuxValuesWithoutASecondCatalogue() throws {
        let keys = DesktopShortcutKey.all
        let symbols = try keys.map { try XCTUnwrap($0.linuxKeysym, $0.name) }
        XCTAssertEqual(Set(symbols).count, keys.count)
        for key in keys {
            let chord = DesktopShortcutBinding(keyCode: key.macKeyCode, modifiers: .command).linuxChord
            XCTAssertEqual(chord?.keysym, key.linuxKeysym)
            XCTAssertEqual(chord?.displayName, "Ctrl+\(key.name)")
        }
    }

    func testKeyValues_MatchGDKLettersPunctuationFunctionAndNavigationKeys() {
        let expected: [UInt16: UInt32] = [
            0: 0x61, 2: 0x64, 18: 0x31, 24: 0x3D, 42: 0x5C,
            36: 0xFF0D, 48: 0xFF09, 49: 0x20, 51: 0xFF08, 53: 0xFF1B,
            122: 0xFFBE, 90: 0xFFD1, 114: 0xFF63, 115: 0xFF50, 116: 0xFF55,
            117: 0xFFFF, 119: 0xFF57, 121: 0xFF56, 123: 0xFF51, 124: 0xFF53,
            125: 0xFF54, 126: 0xFF52
        ]
        for (code, symbol) in expected {
            XCTAssertEqual(DesktopShortcutKey.mac(code)?.linuxKeysym, symbol, "Mac key \(code)")
        }
    }

    func testModifiers_ProjectCommandOptionShiftWithoutCollapsingDistinctMacControl() {
        let binding = DesktopShortcutBinding(keyCode: 2, modifiers: [.command, .option, .shift])
        XCTAssertEqual(binding.linuxChord?.keysym, 0x64)
        XCTAssertEqual(binding.linuxChord?.modifiers, 13)
        XCTAssertEqual(binding.linuxChord?.displayName, "Ctrl+Alt+Shift+D")
        let unsupported: [DesktopShortcutModifiers] = [.control, [.command, .control], .function]
        for modifiers in unsupported {
            XCTAssertNil(DesktopShortcutBinding(keyCode: 2, modifiers: modifiers).linuxChord)
        }
        XCTAssertEqual(DesktopShortcutBinding(keyCode: 122, modifiers: .function).linuxChord?.keysym, 0xFFBE)
        XCTAssertEqual(DesktopShortcutBinding(keyCode: 123, modifiers: .function).linuxChord?.keysym, 0xFF51)
        XCTAssertNil(DesktopShortcutBinding(keyCode: UInt16.max, modifiers: .command).linuxChord)
    }

    func testProjection_DoesNotChangeStoredMacKeyScopeEnabledStateOrDefaults() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for action in DesktopShortcutAction.allCases {
            let binding = action.defaultBinding
            let data = try encoder.encode(binding)
            _ = binding.linuxChord
            let restored = try JSONDecoder().decode(DesktopShortcutBinding.self, from: data)
            XCTAssertEqual(restored, binding)
            XCTAssertEqual(restored.linuxChord, binding.linuxChord)
            XCTAssertEqual(try encoder.encode(binding), data)
        }
    }
}
