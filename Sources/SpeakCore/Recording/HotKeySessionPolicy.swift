import Foundation

/// What started the current recording session. Gestures may stop only the
/// kind of session they started, so a release never ends a recording the user
/// began another way.
public enum HotKeySessionTrigger: String, Codable, Sendable {
    /// A hold past the threshold; the release ends it.
    case hold
    /// A double tap; a single or double tap ends it.
    case doubleTap
    /// A press-to-toggle shortcut; the next press ends it.
    case press
    /// The app's own Record control or another non-shortcut source.
    case other
}

/// The session command a recognised gesture asks for.
public enum HotKeySessionCommand: Equatable, Sendable {
    case start(HotKeySessionTrigger)
    case stop
}

/// The macOS session rules for shortcut gestures, stated once so every host
/// applies them identically:
///
/// - `holdStart` starts a hold session when idle; `holdEnd` stops only a hold session.
/// - `doubleTap` starts a double-tap session when idle and stops one it started.
/// - `singleTap` stops only a double-tap session.
/// - A press-to-toggle press starts a press session when idle and stops any
///   session, preserving the original Windows `Ctrl+Alt+Space` behaviour.
///
/// Styles gate which gestures act, exactly as `allowsHold` and
/// `allowsDoubleTap` do on macOS. Hands-free arming is host-specific and is
/// applied by the host before this policy.
public enum HotKeySessionPolicy {
    public enum Input: Equatable, Sendable {
        case gesture(HotKeyGestureMachine.Gesture)
        case press
    }

    public static func command(
        for input: Input, style: HotKeyActivationStyle, active: HotKeySessionTrigger?
    ) -> HotKeySessionCommand? {
        switch input {
        case .press:
            guard style.togglesOnPress else { return nil }
            return active == nil ? .start(.press) : .stop
        case .gesture(let gesture):
            return command(for: gesture, style: style, active: active)
        }
    }

    private static func command(
        for gesture: HotKeyGestureMachine.Gesture, style: HotKeyActivationStyle, active: HotKeySessionTrigger?
    ) -> HotKeySessionCommand? {
        switch gesture {
        case .holdStart:
            guard style.allowsHold, active == nil else { return nil }
            return .start(.hold)
        case .holdEnd:
            guard style.allowsHold, active == .hold else { return nil }
            return .stop
        case .singleTap:
            guard style.allowsDoubleTap, active == .doubleTap else { return nil }
            return .stop
        case .doubleTap:
            guard style.allowsDoubleTap else { return nil }
            if active == nil { return .start(.doubleTap) }
            return active == .doubleTap ? .stop : nil
        }
    }
}
