import AppKit
import SwiftUI
import XCTest

@testable import SpeakApp

/// The App menu's Start/Stop Recording item advertises the user's configured
/// binding, so the KeyBinding -> SwiftUI bridge has to agree with the AppKit
/// menu that `MenuBarManager` builds from the same binding.
final class KeyBindingSwiftUIBridgeTests: XCTestCase {
  func testDefaultRecordingBinding_mapsToShiftCommandS() {
    let binding = ShortcutAction.startStopRecording.defaultKeyBinding
    XCTAssertEqual(binding.keyEquivalent?.character, "s")
    XCTAssertEqual(binding.eventModifiers, [.command, .shift])
  }

  func testDisabledBinding_hasNoKeyEquivalent() {
    let binding = KeyBinding(keyCode: 1, modifiers: [.command, .shift], isGlobal: true, isEnabled: false)
    XCTAssertNil(binding.keyEquivalent)
  }

  func testNamedKeys_mapToTheirSwiftUIEquivalents() {
    XCTAssertEqual(KeyBinding(keyCode: 49, modifiers: [.command]).keyEquivalent, .space)
    XCTAssertEqual(KeyBinding(keyCode: 53, modifiers: []).keyEquivalent, .escape)
    XCTAssertEqual(KeyBinding(keyCode: 36, modifiers: [.command]).keyEquivalent, .return)
  }

  func testKeysWithoutASwiftUIEquivalent_yieldNoShortcut() {
    // F13 (105) and an unmapped key code both render as multi-character names.
    XCTAssertNil(KeyBinding(keyCode: 105, modifiers: []).keyEquivalent)
    XCTAssertNil(KeyBinding(keyCode: 200, modifiers: [.command]).keyEquivalent)
  }

  func testEveryModifierFlag_isCarriedAcross() {
    let binding = KeyBinding(keyCode: 0, modifiers: [.command, .shift, .option, .control])
    XCTAssertEqual(binding.eventModifiers, [.command, .shift, .option, .control])
  }

  // MARK: - Both menu surfaces render the same bindings (issue #852)

  func testModifiedReturn_isAdvertisedByBothMenuSurfaces() {
    let binding = KeyBinding(keyCode: 36, modifiers: [.command, .shift], isGlobal: false)

    XCTAssertEqual(binding.keyEquivalent, .return, "the SwiftUI App menu shows modified Return")
    XCTAssertFalse(
      binding.menuKeyEquivalent.isEmpty,
      "the AppKit Speak menu used to drop modified Return entirely"
    )

    let item = NSMenuItem(title: "Start/Stop Recording", action: nil, keyEquivalent: binding.menuKeyEquivalent)
    item.keyEquivalentModifierMask = binding.modifiers
    XCTAssertEqual(item.keyEquivalent, String(KeyEquivalent.return.character))
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
  }

  func testMenuKeyEquivalent_agreesWithTheSwiftUIMappingForEveryKeyCode() {
    for keyCode in UInt16(0)...UInt16(200) {
      let binding = KeyBinding(keyCode: keyCode, modifiers: [.command])
      let expected = binding.keyEquivalent.map { String($0.character) } ?? ""
      XCTAssertEqual(
        binding.menuKeyEquivalent,
        expected,
        "key code \(keyCode) renders differently in the two menus"
      )
    }
  }

  func testDisabledBinding_advertisesNoShortcutInEitherMenu() {
    let binding = KeyBinding(keyCode: 36, modifiers: [.command], isGlobal: false, isEnabled: false)

    XCTAssertNil(binding.keyEquivalent)
    XCTAssertEqual(binding.menuKeyEquivalent, "")
  }

  func testUnmappableKey_advertisesNoShortcutInEitherMenu() {
    // F13 has no SwiftUI equivalent, so neither surface may claim it.
    let binding = KeyBinding(keyCode: 105, modifiers: [])

    XCTAssertNil(binding.keyEquivalent)
    XCTAssertEqual(binding.menuKeyEquivalent, "")
  }

  func testLetterKeys_useTheLowercasedMenuCharacter() {
    XCTAssertEqual(KeyBinding(keyCode: 1, modifiers: [.command, .shift]).menuKeyEquivalent, "s")
    XCTAssertEqual(KeyBinding(keyCode: 49, modifiers: [.command]).menuKeyEquivalent, " ")
    XCTAssertEqual(KeyBinding(keyCode: 53, modifiers: []).menuKeyEquivalent, "\u{1B}")
  }
}
