import Foundation
import CLinuxSupport
import SpeakDesktop

/// General › Launch at login on Linux. Outside Flatpak the app owns an XDG
/// autostart entry, `$XDG_CONFIG_HOME/autostart/<app id>.desktop`, which GNOME,
/// KDE, XFCE and other session managers start at login. The entry is the
/// record: removing it, or KDE's `Hidden=true`, in the desktop's startup
/// settings shows here as off. Inside Flatpak the sandbox cannot see that
/// folder, so the Background portal writes the entry, with a `flatpak run`
/// command line, and the state it last reported stands in for reading it.
public enum LinuxLoginItem {
    public static let appID = "com.justspeaktoit.JustSpeakToIt"

    public static func entryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let config: URL
        if let home = environment["XDG_CONFIG_HOME"], home.hasPrefix("/") {
            config = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            config = home.appendingPathComponent(".config", isDirectory: true)
        }
        return config.appendingPathComponent("autostart/\(appID).desktop")
    }

    /// The entry that starts `executable` minimised at login.
    public static func autostartEntry(executable: String) -> String {
        [
            "[Desktop Entry]",
            "Type=Application",
            "Name=Just Speak to It",
            "Comment=Starts Just Speak to It minimised, so dictation is always one shortcut away.",
            "Exec=\(execValue([executable, DesktopLoginItem.launchArgument]))",
            "Icon=\(appID)",
            "Terminal=false",
            "X-GNOME-Autostart-enabled=true",
            ""
        ].joined(separator: "\n")
    }

    /// An Exec value: arguments quoted as the Desktop Entry Specification
    /// requires, `%` doubled so it is not a field code, then escaped as a
    /// string value, which is why a literal backslash ends up as four.
    static func execValue(_ arguments: [String]) -> String {
        let reserved = Set(" \t\n\"'\\><~|&;$*?#()`")
        let quoted = arguments.map { argument -> String in
            let doubled = argument.replacingOccurrences(of: "%", with: "%%")
            guard doubled.isEmpty || doubled.contains(where: reserved.contains) else { return doubled }
            var escaped = ""
            for character in doubled {
                if "\"`$\\".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            return "\"\(escaped)\""
        }
        var value = ""
        for character in quoted.joined(separator: " ") {
            switch character {
            case "\\": value += "\\\\"
            case "\n": value += "\\n"
            case "\t": value += "\\t"
            case "\r": value += "\\r"
            default: value.append(character)
            }
        }
        return value
    }

    /// Whether a desktop entry's main group leaves it enabled.
    static func isEnabled(entry: String) -> Bool {
        var inMainGroup = false
        for line in entry.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inMainGroup = trimmed == "[Desktop Entry]"
                continue
            }
            guard inMainGroup, let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "Hidden", value == "true" { return false }
            if key == "X-GNOME-Autostart-enabled", value == "false" { return false }
        }
        return true
    }

    /// The autostart entry's state outside Flatpak.
    public static func state(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> DesktopLoginItemState {
        guard let data = FileManager.default.contents(atPath: entryURL(environment: environment).path),
              let entry = String(data: data, encoding: .utf8) else { return .disabled }
        return isEnabled(entry: entry) ? .enabled : .disabled
    }

    /// Writes or removes the autostart entry outside Flatpak.
    public static func setEnabled(
        _ enabled: Bool, executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DesktopLoginItemState {
        let url = entryURL(environment: environment)
        let manager = FileManager.default
        if enabled {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(autostartEntry(executable: executable).utf8).write(to: url, options: .atomic)
        } else if (try? manager.attributesOfItem(atPath: url.path)) != nil {
            try manager.removeItem(at: url)
        }
        return state(environment: environment)
    }

    /// Inside Flatpak: asks the Background portal. Blocks while the desktop
    /// asks the user, up to five minutes; never call it on the UI thread.
    public static func requestThroughPortal(_ enabled: Bool, command: String) throws -> DesktopLoginItemState {
        let strings: [String] = [command, DesktopLoginItem.launchArgument]
        let arguments: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer($0) } + [nil]
        var reached: Int32 = 0
        try pointers.withUnsafeBufferPointer { commandline in
            try LinuxNative.call {
                jsti_background_request(
                    enabled ? 1 : 0, "Start Just Speak to It minimised when you sign in.", commandline.baseAddress,
                    &reached, $0, $1
                )
            }
        }
        switch reached {
        case 1: return .enabled
        case 2: return .disabledBySystem
        default: return .disabled
        }
    }

    public static var portalAvailable: Bool { jsti_portal_available("org.freedesktop.portal.Background", nil) == 1 }
}
