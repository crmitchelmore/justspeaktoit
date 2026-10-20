import Foundation
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The global dictation shortcut: the GlobalShortcuts portal on Wayland
/// desktops that offer it, a passive X11 key grab in X11 sessions, and always
/// the `--toggle` command that users can bind in any desktop's settings.
final class LinuxShortcuts: @unchecked Sendable {
    static let portalShortcutID = "toggle-dictation"
    /// X11 Ctrl+Alt+Space: ControlMask | Mod1Mask and XK_space.
    static let x11Modifiers: UInt32 = 0x4 | 0x8
    static let x11Keysym: UInt32 = 0x20

    private let lock = NSLock()
    private var currentHint = "Checking the desktop for a global shortcut…"
    private let lifetime = DesktopShortcutListenerLifetime()

    private struct Registration: Sendable {
        let name: String
        let hint: String
        let cleanup: (@Sendable () -> Void)?
    }

    var hint: String { lock.withLock { currentHint } }

    /// The command users bind when no shortcut service exists.
    static var toggleCommand: String {
        let environment = ProcessInfo.processInfo.environment
        if let app = environment["FLATPAK_ID"], !app.isEmpty { return "flatpak run \(app)" }
        return URL(fileURLWithPath: CommandLine.arguments.first ?? "justspeaktoit").lastPathComponent
    }

    /// Chooses and starts a shortcut service off the GTK thread: binding
    /// through the portal can show a desktop dialog.
    func start(_ holder: LinuxEventContext) {
        guard lifetime.begin() else { return }
        let session = LinuxHostPlatform.session
        let callback = LinuxShortcutCallback(holder: holder, lifetime: lifetime)
        Thread.detachNewThread { [self, weak holder] in
            guard let registration = Self.register(session: session, callback: callback) else {
                lifetime.finish(cleanup: nil)
                return
            }
            guard lifetime.finish(cleanup: registration.cleanup) else { return }
            lifetime.publish {
                LinuxHostPlatform.shortcutName = registration.name
                lock.withLock { currentHint = registration.hint }
            }
            Task { [self, weak holder] in
                guard let controller = holder?.controller else { return }
                let options = await controller.textOutputOptions()
                lifetime.publish { LinuxWindow.textOutput(options, hint: registration.hint) }
            }
        }
    }

    /// Fences new callbacks/publication and closes an active listener. A blocked
    /// registration cleans itself up when it returns, without retaining the holder.
    func stop() { lifetime.stop() }

    private static func register(
        session: LinuxDesktopSession, callback: LinuxShortcutCallback
    ) -> Registration? {
        guard callback.acceptsCallbacks else { return nil }
        let fallback = "`\(toggleCommand) --toggle`"
        if session.displayServer == .x11 {
            do { return try registerX11(callback) } catch {
                return Registration(
                    name: fallback, hint: "Ctrl+Alt+Space is unavailable (\(error.localizedDescription)) "
                        + session.shortcutAdvice(command: toggleCommand), cleanup: nil
                )
            }
        }
        if LinuxPortal.version(of: LinuxPortal.globalShortcuts) != nil {
            guard callback.acceptsCallbacks else { return nil }
            do { return try registerPortal(callback) } catch {
                return Registration(
                    name: fallback, hint: "The desktop shortcut was not set up (\(error.localizedDescription)). "
                        + session.shortcutAdvice(command: toggleCommand), cleanup: nil
                )
            }
        }
        return Registration(name: fallback, hint: session.shortcutAdvice(command: toggleCommand), cleanup: nil)
    }

    private static func registerX11(_ callback: LinuxShortcutCallback) throws -> Registration {
        let context = Unmanaged.passUnretained(callback).toOpaque()
        try LinuxNative.call {
            jsti_x11_hotkey_start(x11Keysym, x11Modifiers, linuxShortcutPressed, context, $0, $1)
        }
        return Registration(
            name: "Ctrl+Alt+Space",
            hint: "Ctrl+Alt+Space starts or stops dictation in any app. "
                + "You can also bind `\(toggleCommand) --toggle` in your keyboard settings.",
            cleanup: { withExtendedLifetime(callback) { jsti_x11_hotkey_stop() } }
        )
    }

    private static func registerPortal(_ callback: LinuxShortcutCallback) throws -> Registration {
        let context = Unmanaged.passUnretained(callback).toOpaque()
        var trigger = [CChar](repeating: 0, count: 256)
        try LinuxNative.call {
            jsti_shortcuts_start(
                portalShortcutID, "Start or stop dictation", "CTRL+ALT+space", linuxShortcutPressed,
                context, &trigger, trigger.count, $0, $1
            )
        }
        let bound = String(cString: trigger)
        return Registration(
            name: bound.isEmpty ? "the dictation shortcut" : bound,
            hint: (bound.isEmpty ? "Your desktop's dictation shortcut" : bound)
                + " starts or stops dictation. Change it in your desktop's keyboard settings.",
            cleanup: { withExtendedLifetime(callback) { jsti_shortcuts_stop() } }
        )
    }
}

private final class LinuxShortcutCallback: @unchecked Sendable {
    private weak var holder: LinuxEventContext?
    private weak var lifetime: DesktopShortcutListenerLifetime?

    init(holder: LinuxEventContext, lifetime: DesktopShortcutListenerLifetime) {
        self.holder = holder
        self.lifetime = lifetime
    }

    var acceptsCallbacks: Bool { lifetime?.acceptsCallbacks == true }

    func receive(_ pressed: Bool) {
        guard let lifetime, let holder, lifetime.acceptsCallbacks else { return }
        holder.shortcutKey(pressed: pressed, lifetime: lifetime)
    }
}

/// X11 listener or portal thread: presses and releases feed the gestures.
private func linuxShortcutPressed(_ pressed: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LinuxShortcutCallback>.fromOpaque(context).takeUnretainedValue().receive(pressed == 1)
}
