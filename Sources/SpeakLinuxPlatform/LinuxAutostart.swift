import Foundation
import CLinuxSupport

/// Start at login. Inside Flatpak the Background portal owns the choice (the
/// desktop may ask once, and the sandbox cannot see the entry it writes);
/// elsewhere the app writes an XDG autostart entry itself. Both start the app
/// with `--hidden`, so login does not open the window.
public enum LinuxAutostart {
    public static let hiddenArgument = "--hidden"

    /// True inside a Flatpak sandbox.
    public static var isSandboxed: Bool { FileManager.default.fileExists(atPath: "/.flatpak-info") }

    /// `$XDG_CONFIG_HOME/autostart/<app id>.desktop`.
    public static func entryURL(
        applicationID: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let config: URL
        if let value = environment["XDG_CONFIG_HOME"], value.hasPrefix("/") {
            config = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            config = home.appendingPathComponent(".config", isDirectory: true)
        }
        return config.appendingPathComponent("autostart/\(applicationID).desktop")
    }

    /// Whether this app's own XDG entry exists and is not hidden.
    public static func entryEnabled(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return !lines.contains { $0.lowercased() == "hidden=true" }
            && !lines.contains { $0.lowercased() == "x-gnome-autostart-enabled=false" }
    }

    /// The desktop entry that starts `executable` hidden.
    public static func entry(applicationID: String, executable: String) -> String {
        let escaped = executable.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let quoted = executable.contains(where: { $0 == " " || $0 == "\"" || $0 == "\\" })
            ? "\"" + escaped + "\"" : executable
        return """
        [Desktop Entry]
        Type=Application
        Name=Just Speak to It
        Comment=Dictation, started at login
        Exec=\(quoted) \(hiddenArgument)
        Icon=\(applicationID)
        Terminal=false
        X-GNOME-Autostart-enabled=true
        X-JustSpeakToIt-Autostart=true

        """
    }

    /// Writes or removes the XDG entry. Removal only deletes an entry this app wrote.
    public static func setEntry(_ enabled: Bool, at url: URL, applicationID: String, executable: String) throws {
        let manager = FileManager.default
        if enabled {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(entry(applicationID: applicationID, executable: executable).utf8).write(to: url, options: .atomic)
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard text.contains("X-JustSpeakToIt-Autostart=true") else {
            throw LinuxNativeError(
                message: "A start-at-login entry you created is at \(url.path); "
                    + "remove it there to stop starting at login."
            )
        }
        try manager.removeItem(at: url)
    }

    /// Asks the Background portal. Returns whether autostart is now on.
    public static func requestPortal(_ enabled: Bool, command: [String]) throws -> Bool {
        var granted: Int32 = 0
        let reason = enabled ? "Start Just Speak to It when you log in, ready for the dictation shortcut."
            : "Stop starting Just Speak to It when you log in."
        var arguments = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        try arguments.withUnsafeMutableBufferPointer { buffer in
            try buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { argv in
                try LinuxNative.call { jsti_background_request(enabled ? 1 : 0, reason, argv, &granted, $0, $1) }
            }
        }
        return granted == 1
    }
}
