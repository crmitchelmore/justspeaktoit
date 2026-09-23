import Foundation
import CLinuxSupport

/// Thin Swift wrappers over the clipboard, file, X11 and portal parts of the
/// C adapter.
public enum LinuxClipboard {
    public static func write(_ text: String) throws {
        try text.withCString { text in try LinuxNative.call { jsti_clipboard_write(text, $0, $1) } }
    }

    /// The clipboard text, or nil when it holds something other than text.
    public static func read() throws -> String? {
        var pointer: UnsafeMutablePointer<CChar>?
        let result = try LinuxNative.checked(accepting: [1]) { jsti_clipboard_read(&pointer, $0, $1) }
        defer { jsti_free(pointer) }
        guard result == 0, let pointer else { return nil }
        return String(cString: pointer)
    }
}

public enum LinuxFiles {
    /// Creates (or tightens) a folder only the current user can read.
    public static func preparePrivateDirectory(_ url: URL) throws {
        try url.path.withCString { path in try LinuxNative.call { jsti_private_directory_prepare(path, $0, $1) } }
    }

    /// Creates a new empty 0600 file; refuses existing paths and links.
    public static func createPrivateFile(_ url: URL) throws {
        try url.path.withCString { path in try LinuxNative.call { jsti_private_file_create(path, $0, $1) } }
    }

    public static func open(_ url: URL) throws {
        try url.path.withCString { path in try LinuxNative.call { jsti_open_path(path, $0, $1) } }
    }

    /// The app's data folder: $XDG_DATA_HOME/JustSpeakToIt, which Flatpak maps
    /// into ~/.var/app/<app id>/data.
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let data = environment["XDG_DATA_HOME"], data.hasPrefix("/") {
            return URL(fileURLWithPath: data).appendingPathComponent("JustSpeakToIt", isDirectory: true)
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/JustSpeakToIt", isDirectory: true)
    }
}

public enum LinuxX11 {
    public static var isAvailable: Bool { jsti_x11_available() == 1 }

    /// The focused X11 top-level window, unless it belongs to this process.
    public static func captureTarget() -> LinuxInsertionTarget? {
        var window: UInt64 = 0
        var windowClass = [CChar](repeating: 0, count: 256)
        var pid: Int32 = 0
        var error = [CChar](repeating: 0, count: 256)
        guard jsti_x11_active_window(&window, &windowClass, windowClass.count, &pid, &error, error.count) == 0,
              window != 0, pid != getpid() else { return nil }
        let executable = pid > 0
            ? try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") : nil
        let className = String(cString: windowClass)
        return LinuxInsertionTarget(
            kind: .x11Window(window), windowClass: className.isEmpty ? nil : className, executablePath: executable
        )
    }

    /// Returns false when `window` is no longer the active window.
    public static func paste(window: UInt64, shift: Bool) throws -> Bool {
        let result = try LinuxNative.checked(accepting: [2]) { jsti_x11_paste(window, shift ? 1 : 0, $0, $1) }
        return result == 0
    }
}

public enum LinuxPortal {
    public static let globalShortcuts = "org.freedesktop.portal.GlobalShortcuts"
    public static let remoteDesktop = "org.freedesktop.portal.RemoteDesktop"
    public static let clipboard = "org.freedesktop.portal.Clipboard"

    /// The interface's version when the desktop portal offers it.
    public static func version(of interface: String) -> UInt32? {
        var version: UInt32 = 0
        return jsti_portal_available(interface, &version) == 1 ? version : nil
    }

    /// Starts (or resumes, with a restore token) the keyboard session. Returns
    /// a new restore token when the portal issued one.
    public static func startRemoteDesktop(restoreToken: String?) throws -> String? {
        var token = [CChar](repeating: 0, count: 512)
        try (restoreToken ?? "").withCString { restore in
            try LinuxNative.call { jsti_remote_desktop_start(restore, &token, token.count, $0, $1) }
        }
        let issued = String(cString: token)
        return issued.isEmpty ? nil : issued
    }

    /// 0 inactive, 1 keyboard only, 2 keyboard with the shared clipboard.
    public static var remoteDesktopState: Int32 { jsti_remote_desktop_active() }

    public static func remotePaste(text: String?, shift: Bool) throws {
        if let text {
            try text.withCString { text in
                try LinuxNative.call { jsti_remote_desktop_paste(text, shift ? 1 : 0, $0, $1) }
            }
        } else {
            try LinuxNative.call { jsti_remote_desktop_paste(nil, shift ? 1 : 0, $0, $1) }
        }
    }

    public static func stopRemoteDesktop() { jsti_remote_desktop_stop() }
}

/// The production output effects over the C adapter. The RemoteDesktop restore
/// token lives in the keyring, because it grants keyboard input.
public struct LinuxOutputNativeAdapter: LinuxOutputNative {
    public static let restoreTokenCredential = "linux-remote-desktop-restore-token"

    public init() {}

    public func readClipboard() throws -> String? { try LinuxClipboard.read() }
    public func writeClipboard(_ text: String) throws { try LinuxClipboard.write(text) }
    public func x11Paste(window: UInt64, shift: Bool) throws -> Bool {
        // Let the clipboard owner settle before the target asks for it.
        Thread.sleep(forTimeInterval: 0.05)
        return try LinuxX11.paste(window: window, shift: shift)
    }

    public func prepareRemoteDesktop() throws -> Bool {
        if LinuxPortal.remoteDesktopState == 0 {
            let saved = try? LinuxCredentialStore.read(name: Self.restoreTokenCredential)
            if let token = try LinuxPortal.startRemoteDesktop(restoreToken: saved), token != saved {
                try? LinuxCredentialStore.save(token, name: Self.restoreTokenCredential)
            }
        }
        return LinuxPortal.remoteDesktopState == 2
    }

    public func remotePaste(text: String?, shift: Bool) throws { try LinuxPortal.remotePaste(text: text, shift: shift) }
    public func ownWindowFocused() -> Bool { jsti_window_is_active() == 1 }
    public func notify(title: String, body: String) { jsti_notify(title, body) }
    public func sleep(milliseconds: Int) { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000) }
}
