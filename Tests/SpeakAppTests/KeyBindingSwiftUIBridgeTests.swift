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
}
