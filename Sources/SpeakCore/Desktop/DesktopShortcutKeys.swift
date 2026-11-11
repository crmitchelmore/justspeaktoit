import Foundation

/// Keys a shortcut may use, keyed by the Mac virtual key code that the shared
/// preference stores. Hosts translate to their own key codes through this one
/// table, so a binding recorded on either platform names the same physical key.
public struct DesktopShortcutKey: Hashable, Sendable {
    public let macKeyCode: UInt16
    /// The Win32 virtual-key code for the same key.
    public let windowsVirtualKey: UInt32
    public let name: String
    /// Function and navigation keys, which the Mac reports with the Fn flag.
    public let isFunctionKey: Bool

    init(_ macKeyCode: UInt16, _ windowsVirtualKey: UInt32, _ name: String, function: Bool = false) {
        self.macKeyCode = macKeyCode
        self.windowsVirtualKey = windowsVirtualKey
        self.name = name
        isFunctionKey = function
    }

    public static let all: [DesktopShortcutKey] = {
        let letters: [(UInt16, Character)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
            (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z")
        ]
        let digits: [(UInt16, Character)] = [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"),
            (25, "9")
        ]
        var keys = (letters + digits).map { code, character in
            DesktopShortcutKey(code, UInt32(character.asciiValue ?? 0), String(character))
        }
        keys += [
            DesktopShortcutKey(36, 0x0D, "Enter"), DesktopShortcutKey(48, 0x09, "Tab"),
            DesktopShortcutKey(49, 0x20, "Space"), DesktopShortcutKey(51, 0x08, "Backspace"),
            DesktopShortcutKey(53, 0x1B, "Esc"), DesktopShortcutKey(24, 0xBB, "="),
            DesktopShortcutKey(27, 0xBD, "-"), DesktopShortcutKey(30, 0xDD, "]"),
            DesktopShortcutKey(33, 0xDB, "["), DesktopShortcutKey(39, 0xDE, "'"),
            DesktopShortcutKey(41, 0xBA, ";"), DesktopShortcutKey(42, 0xDC, "\\"),
            DesktopShortcutKey(43, 0xBC, ","), DesktopShortcutKey(44, 0xBF, "/"),
            DesktopShortcutKey(47, 0xBE, "."), DesktopShortcutKey(50, 0xC0, "`")
        ]
        let functionCodes: [UInt16] = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90
        ]
        keys += functionCodes.enumerated().map { index, code in
            DesktopShortcutKey(code, 0x70 + UInt32(index), "F\(index + 1)", function: true)
        }
        keys += [
            DesktopShortcutKey(114, 0x2D, "Insert", function: true),
            DesktopShortcutKey(115, 0x24, "Home", function: true),
            DesktopShortcutKey(116, 0x21, "Page Up", function: true),
            DesktopShortcutKey(117, 0x2E, "Delete", function: true),
            DesktopShortcutKey(119, 0x23, "End", function: true),
            DesktopShortcutKey(121, 0x22, "Page Down", function: true),
            DesktopShortcutKey(123, 0x25, "Left", function: true),
            DesktopShortcutKey(124, 0x27, "Right", function: true),
            DesktopShortcutKey(125, 0x28, "Down", function: true),
            DesktopShortcutKey(126, 0x26, "Up", function: true)
        ]
        return keys
    }()

    private static let byMacKeyCode = Dictionary(uniqueKeysWithValues: all.map { ($0.macKeyCode, $0) })
    private static let byWindowsVirtualKey = Dictionary(uniqueKeysWithValues: all.map { ($0.windowsVirtualKey, $0) })

    public static func mac(_ keyCode: UInt16) -> DesktopShortcutKey? { byMacKeyCode[keyCode] }
    public static func windows(_ virtualKey: UInt32) -> DesktopShortcutKey? { byWindowsVirtualKey[virtualKey] }

    /// Mac key codes that may be bound without a modifier: the ISO §/± key,
    /// F13-F20 and Insert/Help. Mirrors `KeyCodeMapping.singleKeyHotKeyCodes`.
    public static let singleKeyMacKeyCodes: Set<UInt16> = [10, 64, 79, 80, 90, 105, 106, 107, 113, 114]

    public static let unsupportedSingleKeyMessage =
        "Use Command, Option, Shift, or Control with this key. F13-F20 and Insert can be used alone."

    /// Ordinary unmodified keys would steal normal typing, so only the
    /// dedicated keys above may be used alone, exactly as on the Mac.
    public static func isRecordable(macKeyCode: UInt16, hasModifiers: Bool) -> Bool {
        hasModifiers || singleKeyMacKeyCodes.contains(macKeyCode)
    }
}

/// A binding as Win32 `RegisterHotKey` expects it.
public struct DesktopShortcutWindowsChord: Hashable, Sendable {
    public static let alt: UInt32 = 0x0001
    public static let control: UInt32 = 0x0002
    public static let shift: UInt32 = 0x0004

    public let modifiers: UInt32
    public let virtualKey: UInt32

    public init(modifiers: UInt32, virtualKey: UInt32) {
        self.modifiers = modifiers & (Self.alt | Self.control | Self.shift)
        self.virtualKey = virtualKey
    }

    /// Global registration needs Ctrl or Alt, except for the dedicated keys
    /// (F13-F20 and Insert) that may be used alone, so normal typing is never stolen.
    public var canWorkInOtherApps: Bool {
        if modifiers & (Self.control | Self.alt) != 0 { return true }
        guard let key = DesktopShortcutKey.windows(virtualKey) else { return false }
        return DesktopShortcutKey.singleKeyMacKeyCodes.contains(key.macKeyCode)
    }

    public var displayName: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("Ctrl") }
        if modifiers & Self.alt != 0 { parts.append("Alt") }
        if modifiers & Self.shift != 0 { parts.append("Shift") }
        parts.append(DesktopShortcutKey.windows(virtualKey)?.name ?? String(format: "Key 0x%02X", virtualKey))
        return parts.joined(separator: "+")
    }
}

extension DesktopShortcutBinding {
    /// Command maps to Ctrl, Option to Alt and Shift to Shift. A Mac Control
    /// chord has no distinct Windows modifier and Fn has none at all, so such
    /// bindings stay stored for the Mac and are not registered on Windows.
    public var windowsChord: DesktopShortcutWindowsChord? {
        windowsUnsupportedReason == nil ? unsafeWindowsChord : nil
    }

    public var windowsUnsupportedReason: String? {
        guard let key = DesktopShortcutKey.mac(keyCode) else {
            return "Uses a Mac key with no Windows equivalent."
        }
        if modifiers.contains(.control) { return "Uses the Mac Control key, which Windows has no separate key for." }
        if modifiers.contains(.function), !key.isFunctionKey { return "Uses the Mac Fn key." }
        return nil
    }

    /// The Windows key name, or the Mac symbols when Windows cannot use the binding.
    public var windowsDisplayName: String {
        if let chord = windowsChord { return chord.displayName }
        let name = DesktopShortcutKey.mac(keyCode)?.name ?? "Key \(keyCode)"
        return modifiers.macSymbols + name + " (Mac only)"
    }

    /// The binding for a Windows chord, or nil when the key has no Mac equivalent
    /// and so could not be stored in the shared preference.
    public init?(windows chord: DesktopShortcutWindowsChord, isGlobal: Bool, isEnabled: Bool) {
        guard let key = DesktopShortcutKey.windows(chord.virtualKey) else { return nil }
        var modifiers: DesktopShortcutModifiers = []
        if chord.modifiers & DesktopShortcutWindowsChord.control != 0 { modifiers.insert(.command) }
        if chord.modifiers & DesktopShortcutWindowsChord.alt != 0 { modifiers.insert(.option) }
        if chord.modifiers & DesktopShortcutWindowsChord.shift != 0 { modifiers.insert(.shift) }
        self.init(keyCode: key.macKeyCode, modifiers: modifiers, isGlobal: isGlobal, isEnabled: isEnabled)
    }

    private var unsafeWindowsChord: DesktopShortcutWindowsChord? {
        guard let key = DesktopShortcutKey.mac(keyCode) else { return nil }
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= DesktopShortcutWindowsChord.control }
        if modifiers.contains(.option) { flags |= DesktopShortcutWindowsChord.alt }
        if modifiers.contains(.shift) { flags |= DesktopShortcutWindowsChord.shift }
        return DesktopShortcutWindowsChord(modifiers: flags, virtualKey: key.windowsVirtualKey)
    }
}
