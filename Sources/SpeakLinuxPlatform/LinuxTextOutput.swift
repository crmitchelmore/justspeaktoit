import Foundation

/// Persisted automatic output choices. Unknown or missing keys keep the
/// defaults, so a settings file from a newer build still loads.
public struct LinuxTextOutputOptions: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        /// Put the transcript on the clipboard and send the paste keystroke to
        /// the app that was focused when dictation started.
        case paste
        /// Copy only; the user pastes.
        case clipboardOnly
    }

    public var method: Method
    /// Put the previous clipboard text back after a paste (X11 only; Wayland
    /// does not let a background app read the clipboard).
    public var restoreClipboard: Bool

    public init(method: Method = .paste, restoreClipboard: Bool = true) {
        self.method = method
        self.restoreClipboard = restoreClipboard
    }

    private enum CodingKeys: String, CodingKey { case method, restoreClipboard }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try? container.decodeIfPresent(String.self, forKey: .method)
        method = raw.flatMap(Method.init(rawValue:)) ?? .paste
        restoreClipboard = (try? container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)) ?? true
    }

    public var savedStatus: String {
        switch method {
        case .paste:
            return restoreClipboard
                ? "Text output saved: finished dictation is pasted into the app you were using, then the clipboard is restored."
                : "Text output saved: finished dictation is pasted into the app you were using."
        case .clipboardOnly:
            return "Text output saved: finished recordings are copied to the clipboard."
        }
    }
}

/// Where a shortcut-started recording should deliver its text. Captured when
/// the shortcut fires, before anything else can take focus.
public struct LinuxInsertionTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An X11 top-level window, re-verified before the paste.
        case x11Window(UInt64)
        /// Wayland hides other clients: whatever is focused at delivery
        /// receives the paste, unless it is this app's own window.
        case focusedApplication
    }

    public let kind: Kind
    /// WM_CLASS class of the X11 window, used to choose Ctrl+Shift+V for terminals.
    public let windowClass: String?
    /// The owning executable, for app profiles. X11 only.
    public let executablePath: String?

    public init(kind: Kind, windowClass: String? = nil, executablePath: String? = nil) {
        self.kind = kind
        self.windowClass = windowClass
        self.executablePath = executablePath
    }

    /// Terminals paste with Ctrl+Shift+V; Ctrl+V would send a literal ^V.
    public var prefersShiftPaste: Bool {
        guard let windowClass else { return false }
        return LinuxTerminals.isTerminal(windowClass: windowClass)
    }
}

public enum LinuxTerminals {
    private static let classes: Set<String> = [
        "gnome-terminal", "gnome-terminal-server", "org.gnome.terminal", "org.gnome.console", "kgx", "konsole",
        "org.kde.konsole", "xterm", "uxterm", "urxvt", "rxvt", "alacritty", "kitty", "foot", "footclient",
        "terminator", "tilix", "com.gexperts.tilix", "xfce4-terminal", "lxterminal", "mate-terminal", "st",
        "st-256color", "wezterm", "org.wezfurlong.wezterm", "ghostty", "com.mitchellh.ghostty", "yakuake",
        "guake", "qterminal", "terminology", "blackbox", "com.raggesilver.blackbox", "ptyxis", "org.gnome.ptyxis"
    ]

    public static func isTerminal(windowClass: String) -> Bool {
        classes.contains(windowClass.lowercased())
    }
}

/// How one finished recording's text reaches the user.
public enum LinuxOutputPlan: Equatable, Sendable {
    /// Copy only, with an optional reason the paste was not attempted.
    case copy(reason: String?)
    case x11Paste(window: UInt64, shift: Bool, restoreClipboard: Bool)
    case portalPaste(shift: Bool)

    public var isClipboard: Bool {
        if case .copy = self { return true }
        return false
    }

    /// Chooses the delivery for a recording from its own snapshot of options
    /// and target; current settings are never read here.
    public static func make(
        options: LinuxTextOutputOptions, target: LinuxInsertionTarget?, session: LinuxDesktopSession,
        portalAvailable: Bool
    ) -> LinuxOutputPlan? {
        if options.method == .clipboardOnly { return .copy(reason: nil) }
        guard let target else { return nil }
        switch target.kind {
        case .x11Window(let window):
            guard session.canUseX11Injection else {
                return .copy(reason: "This session does not allow pasting into other apps.")
            }
            return .x11Paste(window: window, shift: target.prefersShiftPaste, restoreClipboard: options.restoreClipboard)
        case .focusedApplication:
            guard portalAvailable else {
                return .copy(reason: "This desktop has no remote-input portal for pasting.")
            }
            return .portalPaste(shift: target.prefersShiftPaste)
        }
    }
}

/// Native effects the output job drives. The app uses LinuxOutputNativeAdapter;
/// tests substitute a recorder.
public protocol LinuxOutputNative: Sendable {
    func readClipboard() throws -> String?
    func writeClipboard(_ text: String) throws
    /// Returns false when the target window is no longer focused.
    func x11Paste(window: UInt64, shift: Bool) throws -> Bool
    /// Starts the consented keyboard session if needed; true when the portal
    /// session shares the clipboard.
    func prepareRemoteDesktop() throws -> Bool
    /// `text` nil presses the keys over whatever the clipboard holds.
    func remotePaste(text: String?, shift: Bool) throws
    /// True while this app's own window has keyboard focus.
    func ownWindowFocused() -> Bool
    func notify(title: String, body: String)
    func sleep(milliseconds: Int)
}

/// One automatic output. `perform` blocks and runs off the UI thread and the
/// controller; `cancel` is nonblocking and prevents any later step.
public final class LinuxOutputJob: @unchecked Sendable {
    public let plan: LinuxOutputPlan
    private let native: any LinuxOutputNative
    private let lock = NSLock()
    private var cancelled = false

    /// Delay before a restore, so a slow target reads the transcript first.
    public static let restoreDelayMilliseconds = 750

    public init(plan: LinuxOutputPlan, native: any LinuxOutputNative) {
        self.plan = plan
        self.native = native
    }

    public func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func perform(_ text: String) -> String {
        guard !isCancelled else { return "Output cancelled. Saved to History." }
        switch plan {
        case .copy(let reason):
            return copy(text, reason: reason)
        case .x11Paste(let window, let shift, let restore):
            return x11Paste(text, window: window, shift: shift, restore: restore)
        case .portalPaste(let shift):
            return portalPaste(text, shift: shift)
        }
    }

    private func copy(_ text: String, reason: String?) -> String {
        do {
            try native.writeClipboard(text)
        } catch {
            return "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
        }
        guard let reason else { return "Transcript copied to the clipboard and saved to History." }
        native.notify(title: "Transcript copied", body: "Press Ctrl+V to paste it.")
        return "Transcript copied; press Ctrl+V to paste. \(reason)"
    }

    private func x11Paste(_ text: String, window: UInt64, shift: Bool, restore: Bool) -> String {
        let previous = restore ? (try? native.readClipboard()) ?? nil : nil
        do {
            try native.writeClipboard(text)
            guard !isCancelled else { return "Output cancelled. The transcript is on the clipboard." }
            guard try native.x11Paste(window: window, shift: shift) else {
                native.notify(title: "Transcript copied", body: "The focused window changed. Press Ctrl+V to paste.")
                return "The focused window changed, so nothing was pasted. The transcript is on the clipboard."
            }
        } catch {
            return "Saved. Automatic paste unavailable; select Copy. \(error.localizedDescription)"
        }
        guard restore, let previous else { return "Transcript pasted and saved to History." }
        native.sleep(milliseconds: Self.restoreDelayMilliseconds)
        // Never overwrite something the user copied in the meantime.
        guard ((try? native.readClipboard()) ?? nil) == text else {
            return "Transcript pasted and saved to History."
        }
        do { try native.writeClipboard(previous) } catch {
            return "Transcript pasted. The previous clipboard could not be restored."
        }
        return "Transcript pasted and saved to History. The clipboard was restored."
    }

    private func portalPaste(_ text: String, shift: Bool) -> String {
        if native.ownWindowFocused() {
            return copy(text, reason: "JustSpeakToIt itself was focused, so nothing was pasted.")
        }
        do {
            let sharedClipboard = try native.prepareRemoteDesktop()
            guard !isCancelled else { return "Output cancelled. Saved to History." }
            if sharedClipboard {
                try native.remotePaste(text: text, shift: shift)
            } else {
                try native.writeClipboard(text)
                try native.remotePaste(text: nil, shift: shift)
            }
            return "Transcript pasted and saved to History. It also stays on the clipboard."
        } catch {
            return copy(text, reason: "Automatic paste unavailable: \(error.localizedDescription)")
        }
    }
}
