import Foundation
import CWindowsSupport
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// General > App behaviour > "System resources in use" (issue #1473): reports
/// the registry's holds to the native window, audits the microphone against
/// WASAPI's audio sessions and holds the dictation shortcut's registration.
/// Returns false for other events.
func windowsSystemResourcesEvent(
    _ event: DesktopNativeWindowEvent, value: String, holder: WindowsEventContext
) -> Bool {
    switch event {
    case .systemResourceRelease:
        Task { await DesktopSystemResources.release(value) }
    case .systemResourcesReleaseAll:
        Task {
            let count = await DesktopSystemResources.releaseEverything()
            WindowsSystemResources.log("User released everything: \(count) holds")
            holder.systemResources.sample()
        }
    default: return false
    }
    return true
}

enum WindowsSystemResources {
    static func makeMonitor() -> DesktopSystemResourcesMonitor {
        DesktopNativeSystemResources.monitor(
            osName: "Windows", capturing: jsti_audio_process_capturing, show: show
        )
    }

    static func log(_ line: String) { DesktopNativeSystemResources.log(line) }

    static func show(_ presentation: DesktopSystemResources.Presentation) {
        DesktopNativeSystemResources.show(
            presentation, row: JSTISystemResourceRow.init, view: JSTISystemResourcesView.init,
            set: jsti_window_set_system_resources
        )
    }
}

/// The dictation shortcut's `RegisterHotKey` registration, as reported by
/// WindowsHotKey.cpp after every start, stop or change. It has no release
/// button: without it the only way to dictate is the window. Matches macOS.
final class WindowsHotKeyResource {
    private let hold = DesktopRegistrationHold { name in
        SystemResourceRegistry.shared.acquire(
            kind: .hotKey, title: "Dictation hotkey",
            reason: "Listens for your hotkey through RegisterHotKey. Nothing is recorded.",
            owner: "WindowsHotKey", detail: name
        )
    }
    private var callbacks: NativeCallbackContext<DesktopRegistrationHold>?

    /// Call before the window starts the shortcut.
    func start() {
        guard callbacks == nil else { return }
        let callbacks = NativeCallbackContext(hold)
        self.callbacks = callbacks
        jsti_hotkey_set_registration_observer(windowsHotKeyRegistered, callbacks.pointer)
    }

    /// Clears the observer; a report already in flight resolves to nothing.
    func stop() {
        jsti_hotkey_set_registration_observer(nil, nil)
        callbacks?.unregister()
        callbacks = nil
        hold.update(nil)
    }
}

private func windowsHotKeyRegistered(_ name: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    NativeCallbackContext<DesktopRegistrationHold>.resolve(context)?.update(name.map { String(cString: $0) })
}
