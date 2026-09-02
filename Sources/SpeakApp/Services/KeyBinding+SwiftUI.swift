import AppKit
import SpeakHotKeys
import SwiftUI

/// Bridges a user-configurable `KeyBinding` into the SwiftUI shortcut types so
/// SwiftUI menu commands can advertise the same shortcut `MenuBarManager`
/// installs on the AppKit menu.
extension KeyBinding {
    /// The SwiftUI key for this binding, or `nil` when the binding is disabled or
    /// bound to a key SwiftUI has no equivalent for (function keys, keypad keys).
    var keyEquivalent: KeyEquivalent? {
        guard isEnabled else { return nil }
        switch keyCode {
        case 36: return .return
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        case 115: return .home
        case 116: return .pageUp
        case 117: return .deleteForward
        case 119: return .end
        case 121: return .pageDown
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:
            // Printable keys map through the shared key-code table; anything the
            // table renders as a name ("F5", "PgUp", "Key42") has no equivalent.
            let name = KeyCodeMapping.string(for: keyCode)
            guard name.count == 1, let character = name.lowercased().first else { return nil }
            return KeyEquivalent(character)
        }
    }

    /// The SwiftUI modifiers matching this binding's AppKit modifier flags.
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}
