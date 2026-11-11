import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

/// General > "System resources in use" (issue #1473): reports the registry's
/// holds to the GTK group and audits the microphone against the sound server.
/// Returns false for other events.
func linuxSystemResourcesEvent(
    _ event: DesktopNativeWindowEvent, value: String, holder: LinuxEventContext
) -> Bool {
    switch event {
    case .systemResourceRelease:
        Task { await DesktopSystemResources.release(value) }
    case .systemResourcesReleaseAll:
        Task {
            let count = await DesktopSystemResources.releaseEverything()
            LinuxSystemResources.log("User released everything: \(count) holds")
            holder.systemResources.sample()
        }
    default: return false
    }
    return true
}

enum LinuxSystemResources {
    static func makeMonitor() -> DesktopSystemResourcesMonitor {
        DesktopNativeSystemResources.monitor(
            osName: "The sound server", capturing: jsti_audio_process_capturing, show: show
        )
    }

    static func log(_ line: String) { DesktopNativeSystemResources.log(line) }

    static func show(_ presentation: DesktopSystemResources.Presentation) {
        DesktopNativeSystemResources.show(
            presentation, row: JSTISystemResourceRow.init, view: JSTISystemResourcesView.init,
            set: jsti_window_set_system_resources
        )
    }

    /// The dictation shortcut's listener, while one is registered. It has no
    /// release button: without it the only way to dictate is the `--toggle` command.
    static func acquireHotKey(name: String, mechanism: String) -> SystemResourceToken {
        SystemResourceRegistry.shared.acquire(
            kind: .hotKey, title: "Dictation hotkey",
            reason: "Listens for your hotkey through \(mechanism). Nothing is recorded.",
            owner: "LinuxShortcuts", detail: name.isEmpty ? nil : name
        )
    }
}
