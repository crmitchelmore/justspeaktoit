import AppKit
import Foundation
import SpeakHotKeys

/// Represents a keyboard shortcut binding.
struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var isGlobal: Bool
    var isEnabled: Bool

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isGlobal: Bool = true, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isGlobal = isGlobal
        self.isEnabled = isEnabled
    }

    // Custom Codable to handle NSEvent.ModifierFlags
    enum CodingKeys: String, CodingKey {
        case keyCode, modifiersRaw, isGlobal, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawModifiers = try container.decode(UInt.self, forKey: .modifiersRaw)
        modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)
        isGlobal = try container.decode(Bool.self, forKey: .isGlobal)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiersRaw)
        try container.encode(isGlobal, forKey: .isGlobal)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        let isPlus = keyCode == 24 && modifiers.contains(.shift)
        if modifiers.contains(.shift), !isPlus { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(isPlus ? "+" : keyCodeToString(keyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt16) -> String {
        KeyCodeMapping.string(for: code)
    }
}
