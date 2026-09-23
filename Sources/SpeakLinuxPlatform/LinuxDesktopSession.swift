import Foundation

/// What the current desktop session allows, derived only from the process
/// environment so it can be tested without a display.
public struct LinuxDesktopSession: Equatable, Sendable {
    public enum DisplayServer: String, Equatable, Sendable {
        case wayland, x11, unknown
    }

    public let displayServer: DisplayServer
    /// Lower-cased XDG_CURRENT_DESKTOP entries, e.g. ["ubuntu", "gnome"].
    public let desktops: [String]
    public let isFlatpak: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let type = environment["XDG_SESSION_TYPE"]?.lowercased()
        let wayland = !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty
        let x11 = !(environment["DISPLAY"] ?? "").isEmpty
        if type == "wayland" || (type == nil && wayland) {
            displayServer = .wayland
        } else if type == "x11" || (type == nil && x11) || (type == "tty" && x11) {
            displayServer = .x11
        } else if wayland {
            displayServer = .wayland
        } else if x11 {
            displayServer = .x11
        } else {
            displayServer = .unknown
        }
        desktops = (environment["XDG_CURRENT_DESKTOP"] ?? "")
            .split(separator: ":").map { $0.lowercased() }.filter { !$0.isEmpty }
        // Flatpak sets FLATPAK_ID for every sandboxed app process.
        isFlatpak = !(environment["FLATPAK_ID"] ?? "").isEmpty
    }

    public var isGNOME: Bool { desktops.contains("gnome") }
    public var isKDE: Bool { desktops.contains("kde") }
    /// wlroots compositors without the GlobalShortcuts portal.
    public var isWlroots: Bool { desktops.contains { ["sway", "river", "niri", "labwc", "wayfire"].contains($0) } }

    /// X11 input injection reaches other applications only in an X11 session.
    public var canUseX11Injection: Bool { displayServer == .x11 }

    /// A short, honest description of how global shortcuts work here.
    public func shortcutAdvice(command: String) -> String {
        let bind = "bind `\(command) --toggle` to a key in your desktop's keyboard settings"
        switch displayServer {
        case .x11:
            return "Ctrl+Alt+Space starts or stops recording. You can also \(bind)."
        case .wayland where isWlroots:
            return "This compositor has no global shortcut portal: \(bind) (for example bindsym in Sway)."
        case .wayland:
            return "Your desktop asks once to confirm the dictation shortcut. You can also \(bind)."
        case .unknown:
            return "No graphical session was detected. \(bind.prefix(1).uppercased() + bind.dropFirst())."
        }
    }
}
