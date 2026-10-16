import Foundation
import SpeakCore
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

/// The persisted global shortcut. Raw values keep a settings file written by a
/// newer build readable: an unknown style falls back to the Windows default.
struct WindowsHotKeySettings: Codable, Equatable, Sendable {
    static let alt: UInt32 = 0x1, control: UInt32 = 0x2, shift: UInt32 = 0x4
    static let space: UInt32 = 0x20

    var modifiers: UInt32 = control | alt
    var virtualKey: UInt32 = space
    var style: String = HotKeyActivationStyle.windowsDefault.rawValue

    var activation: HotKeyActivationStyle {
        HotKeyActivationStyle(rawValue: style).flatMap {
            HotKeyActivationStyle.windowsStyles.contains($0) ? $0 : nil
        } ?? .windowsDefault
    }

    var name: String { WindowsNative.hotKeyName(modifiers: modifiers, key: virtualKey) }

    /// What finishes a session that `trigger` started, for the status line.
    func finishHint(for trigger: HotKeySessionTrigger) -> String {
        switch trigger {
        case .hold: return "Release \(name) to finish."
        case .doubleTap: return "Tap \(name) to finish."
        case .press: return "Press \(name) to finish."
        case .other:
            return activation.togglesOnPress ? "Press \(name) to finish." : "Select Stop recording to finish."
        }
    }

    var readyHint: String {
        switch activation {
        case .pressToToggle: return "\(name) starts or stops recording."
        case .holdToRecord: return "Hold \(name) to record."
        case .doubleTapToggle: return "Double-tap \(name) to start or stop recording."
        case .holdAndDoubleTap: return "Hold \(name) to record, or double-tap it to start and stop."
        }
    }
}

extension WindowsNative {
    static func hotKeyName(modifiers: UInt32, key: UInt32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard jsti_hotkey_name(modifiers, key, &buffer, buffer.count) == 0 else { return "the shortcut" }
        return String(cString: buffer)
    }

    /// Configures the Shortcut dialog and the combination registered when the
    /// window starts. Invalid saved values fall back to the default shortcut.
    @discardableResult
    static func configureHotKey(_ settings: WindowsHotKeySettings, context: UnsafeMutableRawPointer) -> Bool {
        let styles = HotKeyActivationStyle.windowsStyles
        let names = styles.map(\.displayName)
        let descriptions = styles.map(\.summary)
        let style = Int32(styles.firstIndex(of: settings.activation) ?? 0)
        let press = Int32(styles.firstIndex(of: .pressToToggle) ?? 0)
        return withCStrings(names) { names in
            withCStrings(descriptions) { descriptions in
                jsti_window_set_hotkey(
                    settings.modifiers, settings.virtualKey, names, descriptions, styles.count, style, press,
                    hotKeyEvent, context
                ) == 0
            }
        }
    }

    private static func withCStrings<Result>(
        _ values: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Result
    ) -> Result {
        let pointers: [UnsafeMutablePointer<CChar>] = values.map { value in
            let chars = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let borrowed: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        return borrowed.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}

/// Apply from the native Shortcut dialog, on the UI thread, after the new
/// combination is registered. Gestures restart under the new style at once;
/// saving joins the settings queue like every other setting.
func hotKeyEvent(_ modifiers: UInt32, _ key: UInt32, _ style: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let styles = HotKeyActivationStyle.windowsStyles
    guard styles.indices.contains(Int(style)) else { return }
    let settings = WindowsHotKeySettings(modifiers: modifiers, virtualKey: key, style: styles[Int(style)].rawValue)
    holder.hotKeys.configure(style: settings.activation)
    holder.enqueueSettings {
        await holder.controller.saveHotKey(settings)
        let saved = await holder.controller.hotKeySettings()
        if !WindowsNative.configureHotKey(saved, context: Unmanaged.passUnretained(holder).toOpaque()) {
            WindowsNative.update("The saved shortcut could not be shown. Reopen Keyboard shortcut and try again.")
        }
    }
}

typealias WindowsHotKeySessionState = DesktopHostHotKeySessionState

typealias WindowsHotKeyRequest = DesktopHostShortcutRequest<WindowsHostPlatform>
typealias WindowsHotKeyGestures = DesktopHostShortcutGestures<WindowsHostPlatform>

extension DesktopHostShortcutGestures where Platform == WindowsHostPlatform {
    convenience init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        armDeadline: @escaping (Int32) -> Void = { _ = jsti_window_set_hotkey_deadline($0) },
        deliver: @escaping @Sendable (WindowsHotKeyRequest) async -> Void
    ) {
        self.init(
            clock: clock, armDeadline: armDeadline, executablePath: { $0?.executablePath }, deliver: deliver
        )
    }
}

extension WindowsAppController {
    func saveHotKey(_ hotKey: WindowsHotKeySettings) {
        guard !closed else { return }
        var changed = settings
        changed.hotKey = hotKey
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update("Keyboard shortcut saved. \(hotKey.readyHint)")
        } catch {
            update("The shortcut works until you close the app, but could not be saved: \(error.localizedDescription)")
        }
    }

    /// Applies the shared macOS session rules to one recognised gesture. A
    /// gesture may stop only the kind of session it started, and a start
    /// recognised while an earlier shortcut stop was still finishing is stale.
    func hotKey(_ request: WindowsHotKeyRequest) async {
        await admitShortcut(request)
    }
}
