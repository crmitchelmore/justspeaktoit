import Foundation
import SpeakCore
import SpeakDesktop

/// Persisted automatic output choices. Missing policy retains legacy behavior;
/// supplied destination intent is validated instead of silently retargeted.
public struct LinuxTextOutputOptions: Codable, Equatable, Sendable, DesktopAppSwitchOutputOptions {
    public enum Method: String, Codable, Sendable, CaseIterable {
        /// Put the transcript on the clipboard and send the paste keystroke to
        /// the app that was focused when dictation started.
        case paste
        /// Copy only; the user pastes.
        case clipboardOnly
    }

    public var method: Method
    /// Restore previous plain text while this output still owns the X11 selection.
    /// Wayland retains this choice but cannot confirm paste consumption.
    public var restoreClipboard: Bool
    /// Nil preserves the pre-policy X11/Wayland behavior.
    public var appSwitchDelivery: AppSwitchDelivery?

    // Consent for the captured original field cannot authorize an explicit delivery policy.
    var permitsOriginalObservationalInsertion: Bool { method == .paste && appSwitchDelivery == nil }

    public init(method: Method = .paste, restoreClipboard: Bool = true) {
        self.method = method
        self.restoreClipboard = restoreClipboard
        self.appSwitchDelivery = nil
    }

    private enum CodingKeys: String, CodingKey { case method, restoreClipboard, appSwitchDelivery }

    public init(appSwitchDelivery: AppSwitchDelivery?) {
        self.init()
        self.appSwitchDelivery = appSwitchDelivery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try? container.decodeIfPresent(String.self, forKey: .method)
        method = raw.flatMap(Method.init(rawValue:)) ?? .paste
        restoreClipboard = (try? container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)) ?? true
        appSwitchDelivery = try container.decodeIfPresent(AppSwitchDelivery.self, forKey: .appSwitchDelivery)
    }

    public init(nativeMethod: Int, payload: String) throws {
        let parts = payload.split(separator: "\t", omittingEmptySubsequences: false)
        guard (0...1).contains(nativeMethod), parts.count == 2,
              parts[0].isEmpty || parts[0] == "restore",
              let selection = Int(parts[1]), String(selection) == parts[1] else {
            throw DesktopConfigurationError.invalidField("Text output")
        }
        self.init(method: nativeMethod == 1 ? .clipboardOnly : .paste, restoreClipboard: parts[0] == "restore")
        appSwitchDelivery = try AppSwitchDelivery.desktopPolicy(selection: selection)
    }

    public func savedStatus(canRestoreClipboard: Bool) -> String {
        if method == .paste, let appSwitchDelivery {
            return "Text output saved: \(appSwitchDelivery.displayName). "
                + AppSwitchDelivery.linuxHelp(canTargetApps: canRestoreClipboard)
        }
        switch method {
        case .paste:
            guard canRestoreClipboard else {
                return "Text output saved: finished dictation is pasted into the app focused at delivery. "
                    + "Wayland keeps the transcript on the clipboard; the X11 restoration preference is retained."
            }
            return restoreClipboard
                ? "Text output saved: finished dictation is pasted into the app you were using, "
                    + "then previous clipboard text is restored if the app still owns the selection."
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
    public let processID: Int32?
    public let processIdentity: String?
    public let observationalTarget: LinuxAtspiTarget?

    public init(kind: Kind, windowClass: String? = nil, executablePath: String? = nil) {
        self.kind = kind
        self.windowClass = windowClass
        self.executablePath = executablePath
        self.processID = nil
        self.processIdentity = nil
        self.observationalTarget = nil
    }

    public init(
        kind: Kind, windowClass: String?, executablePath: String?, processID: Int32, processIdentity: String?
    ) {
        self.kind = kind
        self.windowClass = windowClass
        self.executablePath = executablePath
        self.processID = processID
        self.processIdentity = processIdentity
        self.observationalTarget = nil
    }

    public init(
        kind: Kind, windowClass: String? = nil, executablePath: String? = nil,
        processID: Int32? = nil, processIdentity: String? = nil, observationalTarget: LinuxAtspiTarget?
    ) {
        self.kind = kind
        self.windowClass = windowClass
        self.executablePath = executablePath
        self.processID = processID
        self.processIdentity = processIdentity
        self.observationalTarget = observationalTarget
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
    case guardedX11(target: LinuxInsertionTarget, policy: AppSwitchDelivery, restoreClipboard: Bool)

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
            if let policy = options.appSwitchDelivery {
                return .guardedX11(target: target, policy: policy, restoreClipboard: options.restoreClipboard)
            }
            return .x11Paste(
                window: window, shift: target.prefersShiftPaste, restoreClipboard: options.restoreClipboard
            )
        case .focusedApplication:
            if options.appSwitchDelivery != nil {
                return .copy(reason: "Wayland cannot verify the original or delivery-time app and field. "
                    + "Your selected app-switch policy is retained; paste manually.")
            }
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
    func x11TargetIsFront(_ target: LinuxInsertionTarget) throws -> Bool
    func x11Paste(target: LinuxInsertionTarget, shift: Bool) throws -> Bool
    func readClipboard() throws -> String?
    func writeClipboard(_ text: String) throws
    func writeOwnedClipboard(_ text: String) throws -> UInt64
    /// Atomically restores only the selection created by this receipt.
    func restoreClipboard(_ text: String, ownership: UInt64) throws -> Bool
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

extension LinuxOutputNative {
    public func x11TargetIsFront(_ target: LinuxInsertionTarget) throws -> Bool { false }
    public func x11Paste(target: LinuxInsertionTarget, shift: Bool) throws -> Bool { false }
}

/// One automatic output. `perform` blocks and runs off the UI thread and the
/// controller; `cancel` is nonblocking and prevents any later step.
public final class LinuxOutputJob: @unchecked Sendable {
    public let plan: LinuxOutputPlan
    private let native: any LinuxOutputNative
    private let lock = NSLock()
    private var cancelled = false
    private let observational: (any LinuxObservationalInsertion)?
    private var observed = false
    public var isClipboard: Bool { observational == nil && plan.isClipboard }
    public var correctionReadback: (any DesktopCorrectionReadback)? {
        lock.withLock { observed && !cancelled ? observational : nil }
    }

    /// Delay before a restore, so a slow target reads the transcript first.
    public static let restoreDelayMilliseconds = 750

    public convenience init(plan: LinuxOutputPlan, native: any LinuxOutputNative) {
        self.init(plan: plan, native: native, options: LinuxTextOutputOptions(), observational: nil)
    }

    public init(
        plan: LinuxOutputPlan, native: any LinuxOutputNative, options: LinuxTextOutputOptions,
        observational: (any LinuxObservationalInsertion)?
    ) {
        self.plan = plan
        self.native = native
        self.observational = options.permitsOriginalObservationalInsertion ? observational : nil
    }

    public func cancel() {
        lock.withLock { cancelled = true; observed = false }
        observational?.cancel()
    }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func perform(_ text: String) -> String {
        performResult(text).status
    }

    public func performResult(_ text: String) -> DesktopTextOutputResult {
        guard !isCancelled else {
            return DesktopTextOutputResult(.cancelled, status: "Output cancelled. Saved to History.")
        }
        if let observational {
            switch observational.insert(text) {
            case .unavailableBeforeDispatch: break
            case .observedSpan:
                let eligible = lock.withLock {
                    guard !cancelled else { return false }
                    observed = true
                    return true
                }
                return DesktopTextOutputResult(
                    eligible ? .observedInsertion : .cancelled,
                    status: "AT-SPI text was observed in the original field, not acknowledged as our mutation. "
                        + "Check the field; app-origin changes may also be learned."
                )
            case .indeterminateAfterDispatch:
                observational.cancel()
                return DesktopTextOutputResult(
                    .failed,
                    status: "AT-SPI insertion is indeterminate. Nothing was retried or pasted. "
                        + "Check the original field before copying from History."
                )
            }
        }
        guard !isCancelled else {
            return DesktopTextOutputResult(.cancelled, status: "Output cancelled. Check History.")
        }
        switch plan {
        case .copy(let reason):
            return copy(text, reason: reason)
        case .x11Paste(let window, let shift, let restore):
            return x11Paste(text, window: window, shift: shift, restore: restore)
        case .portalPaste(let shift):
            return portalPaste(text, shift: shift)
        case .guardedX11(let target, let policy, let restore):
            do {
                guard try native.x11TargetIsFront(target), !native.ownWindowFocused() else {
                    return copy(text, reason: policy == .currentApp
                        ? "A new app/field cannot be safely verified on this X11 route. Paste manually."
                        : "The original app is unavailable or no longer in front. Background X11 insertion is unsupported.")
                }
                guard case .x11Window(let window) = target.kind else {
                    return copy(text, reason: "The captured X11 destination is unavailable.")
                }
                return x11Paste(
                    text, window: window, shift: target.prefersShiftPaste, restore: restore, guardedTarget: target
                )
            } catch {
                return copy(text, reason: "The original destination could not be verified: \(error.localizedDescription)")
            }
        }
    }

    private func copy(_ text: String, reason: String?) -> DesktopTextOutputResult {
        guard !isCancelled else {
            return DesktopTextOutputResult(.cancelled, status: "Output cancelled. Saved to History.")
        }
        do {
            try native.writeClipboard(text)
        } catch {
            return DesktopTextOutputResult(
                .failed, status: "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
            )
        }
        guard let reason else {
            return DesktopTextOutputResult(.copied, status: "Transcript copied to the clipboard and saved to History.")
        }
        native.notify(title: "Transcript copied", body: "Press Ctrl+V to paste it.")
        return DesktopTextOutputResult(.recoveryCopy, status: "Transcript copied; press Ctrl+V to paste. \(reason)")
    }

    private func x11Paste(
        _ text: String, window: UInt64, shift: Bool, restore: Bool, guardedTarget: LinuxInsertionTarget? = nil
    ) -> DesktopTextOutputResult {
        var previous: String?
        var readFailure: String?
        if restore {
            do { previous = try native.readClipboard() } catch { readFailure = error.localizedDescription }
        }
        var ownership: UInt64?
        do {
            if previous != nil {
                ownership = try native.writeOwnedClipboard(text)
            } else {
                try native.writeClipboard(text)
            }
            guard !isCancelled else {
                return DesktopTextOutputResult(
                    .cancelled, status: "Output cancelled. The transcript is on the clipboard."
                )
            }
            let pasted: Bool
            if let guardedTarget {
                pasted = try native.x11Paste(target: guardedTarget, shift: shift)
            } else {
                pasted = try native.x11Paste(window: window, shift: shift)
            }
            guard pasted else {
                native.notify(title: "Transcript copied", body: "The focused window changed. Press Ctrl+V to paste.")
                return DesktopTextOutputResult(
                    .recoveryCopy,
                    status: "The focused window changed, so nothing was pasted. The transcript is on the clipboard."
                )
            }
        } catch {
            return DesktopTextOutputResult(
                .unconfirmedInsertion,
                status: "Saved. Automatic paste could not be confirmed; check the original field before retrying. "
                    + error.localizedDescription
            )
        }
        if let readFailure {
            return unconfirmedPaste(" Previous clipboard text could not be read: \(readFailure)")
        }
        guard restore, let previous, let ownership else { return unconfirmedPaste() }
        return restorePreviousClipboard(previous, ownership: ownership)
    }

    private func restorePreviousClipboard(_ previous: String, ownership: UInt64) -> DesktopTextOutputResult {
        native.sleep(milliseconds: Self.restoreDelayMilliseconds)
        guard !isCancelled else { return unconfirmedPaste() }
        do {
            guard try native.restoreClipboard(previous, ownership: ownership) else {
                return unconfirmedPaste()
            }
        } catch {
            return unconfirmedPaste(" Previous clipboard text could not be restored: \(error.localizedDescription)")
        }
        return unconfirmedPaste(" The clipboard was restored.")
    }

    private func portalPaste(_ text: String, shift: Bool) -> DesktopTextOutputResult {
        if native.ownWindowFocused() {
            return copy(text, reason: "JustSpeakToIt itself was focused, so nothing was pasted.")
        }
        do {
            let sharedClipboard = try native.prepareRemoteDesktop()
            guard !isCancelled else {
                return DesktopTextOutputResult(.cancelled, status: "Output cancelled. Saved to History.")
            }
            if sharedClipboard {
                try native.remotePaste(text: text, shift: shift)
            } else {
                try native.writeClipboard(text)
                try native.remotePaste(text: nil, shift: shift)
            }
            return unconfirmedPaste(" It also stays on the clipboard.")
        } catch {
            return copy(text, reason: "Automatic paste unavailable: \(error.localizedDescription)")
        }
    }

    private func unconfirmedPaste(_ detail: String = "") -> DesktopTextOutputResult {
        DesktopTextOutputResult(
            .unconfirmedInsertion,
            status: "Paste keys sent; insertion could not be confirmed. Saved to History." + detail
        )
    }
}
