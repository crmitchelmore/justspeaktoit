import Foundation

extension DesktopShortcutKey {
    /// X11 keysyms are also GDK's portable key values; no native framework is
    /// needed to project the canonical key table.
    public var linuxKeysym: UInt32? {
        if name.utf8.count == 1, let ascii = name.utf8.first {
            return UInt32((65...90).contains(ascii) ? ascii + 32 : ascii)
        }
        if (0x70...0x83).contains(windowsVirtualKey) { return 0xFFBE + windowsVirtualKey - 0x70 }
        switch windowsVirtualKey {
        case 0x08, 0x09, 0x0D, 0x1B: return 0xFF00 + windowsVirtualKey
        case 0x24: return 0xFF50
        case 0x25: return 0xFF51
        case 0x26: return 0xFF52
        case 0x27: return 0xFF53
        case 0x28: return 0xFF54
        case 0x21: return 0xFF55
        case 0x22: return 0xFF56
        case 0x23: return 0xFF57
        case 0x2D: return 0xFF63
        case 0x2E: return 0xFFFF
        case 0x20: return 0x20
        default: return nil
        }
    }
}

public struct DesktopShortcutLinuxChord: Hashable, Sendable {
    public static let shift: UInt32 = 1
    public static let control: UInt32 = 4
    public static let alt: UInt32 = 8
    public let keysym: UInt32
    public let modifiers: UInt32

    public init(keysym: UInt32, modifiers: UInt32) {
        self.keysym = keysym
        self.modifiers = modifiers & (Self.shift | Self.control | Self.alt)
    }

    public var displayName: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("Ctrl") }
        if modifiers & Self.alt != 0 { parts.append("Alt") }
        if modifiers & Self.shift != 0 { parts.append("Shift") }
        parts.append(DesktopShortcutKey.all.first { $0.linuxKeysym == keysym }?.name
            ?? String(format: "Key 0x%X", keysym))
        return parts.joined(separator: "+")
    }
}

extension DesktopShortcutBinding {
    /// As on Windows, Command projects to Ctrl and Option to Alt. A distinct
    /// Mac Control binding remains preserved rather than collapsing into Ctrl.
    public var linuxChord: DesktopShortcutLinuxChord? {
        guard let key = DesktopShortcutKey.mac(keyCode), let keysym = key.linuxKeysym,
              !modifiers.contains(.control), !modifiers.contains(.function) || key.isFunctionKey else { return nil }
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= DesktopShortcutLinuxChord.control }
        if modifiers.contains(.option) { flags |= DesktopShortcutLinuxChord.alt }
        if modifiers.contains(.shift) { flags |= DesktopShortcutLinuxChord.shift }
        return DesktopShortcutLinuxChord(keysym: keysym, modifiers: flags)
    }
}
