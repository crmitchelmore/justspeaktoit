import Foundation

/// General › Launch at login on Windows and Linux: the Mac's login item
/// (`AppSettings.runAtLogin`). The system's own registration is the record
/// wherever a host can read it, so a change made in the system's startup
/// settings shows in the app too. A login launch carries `launchArgument`,
/// and the app starts with its window minimised: the shortcut and the tray are
/// ready, and nothing takes focus from what the user opens first.
public enum DesktopLoginItemState: Int32, Sendable, Equatable, CaseIterable {
    // Raw values cross the hosts' C ABI; keep them stable.
    case disabled = 0
    case enabled = 1
    /// Turned off in the system's startup settings, by the user or by policy.
    /// Only the system can turn it back on.
    case disabledBySystem = 2
    /// Required by policy; the app cannot turn it off.
    case enabledBySystem = 3
    /// This installation cannot register a login item.
    case unavailable = 4

    public var launchesAtLogin: Bool { self == .enabled || self == .enabledBySystem }
    /// Whether the app's switch can change it.
    public var isChangeable: Bool { self == .enabled || self == .disabled }
}

public enum DesktopLoginItem {
    public static let launchArgument = "--background"
    public static let title = "Launch at login"

    /// True when the process was started by the login item.
    public static func isLoginLaunch(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(launchArgument)
    }

    /// The line under the switch. `systemSettings` names where the system's
    /// own startup settings live, for example "Settings › Apps › Startup".
    public static func detail(_ state: DesktopLoginItemState, systemSettings: String) -> String {
        switch state {
        case .enabled, .disabled:
            "Start Just Speak to It minimised when you sign in, so dictation is always one shortcut away."
        case .disabledBySystem: "Turned off in \(systemSettings). Turn it on there to launch at login."
        case .enabledBySystem: "Your organisation's policy starts Just Speak to It when you sign in."
        case .unavailable: "This installation of Just Speak to It cannot start at login."
        }
    }

    /// The status line after the switch changes it.
    public static func status(_ state: DesktopLoginItemState, systemSettings: String) -> String {
        switch state {
        case .enabled: "Just Speak to It will start, minimised, when you sign in."
        case .disabled: "Just Speak to It will no longer start when you sign in."
        case .disabledBySystem: "Launch at login is turned off in \(systemSettings)."
        case .enabledBySystem: "Your organisation's policy keeps Launch at login on."
        case .unavailable: "This installation of Just Speak to It cannot start at login."
        }
    }
}
