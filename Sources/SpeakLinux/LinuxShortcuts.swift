import Foundation
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The global dictation shortcut: the GlobalShortcuts portal on Wayland
/// desktops that offer it, a passive X11 key grab in X11 sessions, and always
/// the `--toggle` command that users can bind in any desktop's settings.
/// Press-to-toggle only for now.
final class LinuxShortcuts: @unchecked Sendable {
    static let portalShortcutID = "toggle-dictation"
    /// X11 Ctrl+Alt+Space: ControlMask | Mod1Mask and XK_space.
    static let x11Modifiers: UInt32 = 0x4 | 0x8
    static let x11Keysym: UInt32 = 0x20

    private let lock = NSLock()
    private var currentHint = "Checking the desktop for a global shortcut…"
    private var usingX11 = false
    private var usingPortal = false

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
        let session = LinuxHostPlatform.session
        Thread.detachNewThread { [self] in
            // The holder outlives the listeners: stop() joins them before it goes.
            let context = Unmanaged.passUnretained(holder).toOpaque()
            var hint: String
            var name = "`\(Self.toggleCommand) --toggle`"
            if session.displayServer == .x11 {
                do {
                    try LinuxNative.call {
                        jsti_x11_hotkey_start(Self.x11Keysym, Self.x11Modifiers, linuxShortcutPressed, context, $0, $1)
                    }
                    lock.withLock { usingX11 = true }
                    name = "Ctrl+Alt+Space"
                    hint = "Ctrl+Alt+Space starts or stops dictation in any app. "
                        + "You can also bind `\(Self.toggleCommand) --toggle` in your keyboard settings."
                } catch {
                    hint = "Ctrl+Alt+Space is unavailable (\(error.localizedDescription)) "
                        + session.shortcutAdvice(command: Self.toggleCommand)
                }
            } else if LinuxPortal.version(of: LinuxPortal.globalShortcuts) != nil {
                var trigger = [CChar](repeating: 0, count: 256)
                do {
                    try LinuxNative.call {
                        jsti_shortcuts_start(
                            Self.portalShortcutID, "Start or stop dictation", "CTRL+ALT+space", linuxShortcutPressed,
                            context, &trigger, trigger.count, $0, $1
                        )
                    }
                    lock.withLock { usingPortal = true }
                    let bound = String(cString: trigger)
                    name = bound.isEmpty ? "the dictation shortcut" : bound
                    hint = (bound.isEmpty ? "Your desktop's dictation shortcut" : bound)
                        + " starts or stops dictation. Change it in your desktop's keyboard settings."
                } catch {
                    hint = "The desktop shortcut was not set up (\(error.localizedDescription)). "
                        + session.shortcutAdvice(command: Self.toggleCommand)
                }
            } else {
                hint = session.shortcutAdvice(command: Self.toggleCommand)
            }
            LinuxHostPlatform.shortcutName = name
            lock.withLock { currentHint = hint }
            Task {
                LinuxWindow.textOutput(await holder.controller.textOutputOptions(), hint: hint)
            }
        }
    }

    /// Joins the X11 listener and closes the portal session; no press is
    /// reported after this returns.
    func stop() {
        let (x11, portal) = lock.withLock { (usingX11, usingPortal) }
        if x11 { jsti_x11_hotkey_stop() }
        if portal { jsti_shortcuts_stop() }
        lock.withLock {
            usingX11 = false
            usingPortal = false
        }
    }
}

/// X11 listener or portal thread. Press-to-toggle acts on the press only.
private func linuxShortcutPressed(_ pressed: Int32, _ context: UnsafeMutableRawPointer?) {
    guard pressed == 1, let context else { return }
    Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
        .shortcutToggle(modelIndex: nil, deviceID: nil)
}
