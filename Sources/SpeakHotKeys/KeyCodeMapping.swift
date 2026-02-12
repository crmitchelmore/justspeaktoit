#if os(macOS)
import Foundation

/// Maps macOS virtual key codes to human-readable strings.
public enum KeyCodeMapping {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  public static func string(for keyCode: UInt16) -> String {
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "O"
    case 32: return "U"
    case 33: return "["
    case 34: return "I"
    case 35: return "P"
    case 36: return "↩"
    case 37: return "L"
    case 38: return "J"
    case 39: return "'"
    case 40: return "K"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "N"
    case 46: return "M"
    case 47: return "."
    case 48: return "⇥"
    case 49: return "Space"
    case 50: return "`"
    case 51: return "⌫"
    case 53: return "⎋"
    case 63: return "Fn"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 99: return "F3"
    case 100: return "F8"
    case 101: return "F9"
    case 103: return "F11"
    case 105: return "F13"
    case 107: return "F14"
    case 109: return "F10"
    case 111: return "F12"
    case 113: return "F15"
    case 118: return "F4"
    case 119: return "End"
    case 120: return "F2"
    case 121: return "PgDn"
    case 122: return "F1"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default: return "Key\(keyCode)"
    }
  }

  /// Key codes that are modifier-only keys (should be ignored when recording shortcuts).
  public static let modifierKeyCodes: Set<UInt16> = [
    54, 55,  // Command (left/right)
    56, 60,  // Shift (left/right)
    58, 61,  // Option (left/right)
    59, 62,  // Control (left/right)
    63,  // Fn/Globe
  ]
}

#endif
