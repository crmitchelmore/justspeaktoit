import Foundation

/// How a global dictation shortcut starts and stops recording: the one
/// catalogue of activation styles. Hosts show projections of it and persist
/// the raw values, so never rename a case.
///
/// Capability rule: macOS offers `macOSStyles` and defaults to
/// `holdAndDoubleTap`. Windows offers every style and defaults to
/// `pressToToggle`, the Ctrl+Alt+Space behaviour Windows builds have always
/// shipped: each press starts or stops recording at once, with no gesture
/// delay. macOS has no press-to-toggle shortcut, so it never offers it.
public enum HotKeyActivationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case holdToRecord
    case doubleTapToggle
    case holdAndDoubleTap
    case pressToToggle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .holdToRecord: return "Press & Hold"
        case .doubleTapToggle: return "Double Tap"
        case .holdAndDoubleTap: return "Hold & Double Tap"
        case .pressToToggle: return "Press to Toggle"
        }
    }

    /// Holding past the hold threshold records until the key is released.
    public var allowsHold: Bool { self == .holdToRecord || self == .holdAndDoubleTap }

    /// A double tap starts recording; a single or double tap stops it.
    public var allowsDoubleTap: Bool { self == .doubleTapToggle || self == .holdAndDoubleTap }

    /// Each press starts or stops recording without classifying a gesture, so
    /// the host never needs to observe the release.
    public var togglesOnPress: Bool { self == .pressToToggle }

    /// One sentence for a settings control describing how the shortcut behaves.
    public var summary: String {
        switch self {
        case .holdToRecord: return "Hold the shortcut to record; releasing it stops recording."
        case .doubleTapToggle: return "Double-tap the shortcut to start recording; tap it again to stop."
        case .holdAndDoubleTap:
            return "Hold the shortcut to record until you release it, or double-tap to start and tap again to stop."
        case .pressToToggle: return "Each press starts or stops recording immediately."
        }
    }

    public static let macOSStyles: [HotKeyActivationStyle] = [.holdToRecord, .doubleTapToggle, .holdAndDoubleTap]
    /// Windows lists its default first, then the macOS gesture styles.
    public static let windowsStyles: [HotKeyActivationStyle] = [.pressToToggle] + macOSStyles
    public static let macOSDefault = HotKeyActivationStyle.holdAndDoubleTap
    public static let windowsDefault = HotKeyActivationStyle.pressToToggle
}

/// Canonical gesture timing in seconds, as the macOS hotkey engine applies it.
/// macOS lets people adjust the hold threshold and double-tap window; every
/// host starts from these defaults.
public enum HotKeyGestureTiming {
    public static let defaultHoldThreshold: TimeInterval = 0.35
    public static let defaultDoubleTapWindow: TimeInterval = 0.4

    /// After a double tap, taps are ignored for the double-tap window, at most this long.
    public static let doubleTapCooldownCap: TimeInterval = 0.25

    /// A double tap this close to the previous one is a duplicate and is dropped.
    public static func duplicateDoubleTapGap(window: TimeInterval) -> TimeInterval {
        max(0.2, window * 0.5)
    }

    /// A recording session ignores a double tap this soon after the last one it acted on.
    public static let doubleTapCommandInterval: TimeInterval = 0.25
}
