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
        DesktopSystemResourcesMonitor(
            osName: "The sound server",
            probe: {
                switch jsti_audio_process_capturing() {
                case 1: true
                case 0: false
                default: nil
                }
            },
            publish: { show($0) },
            report: { log($0) }
        )
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data("System resources: \(line)\n".utf8))
    }

    static func show(_ presentation: DesktopSystemResources.Presentation) {
        let strings = DesktopNativeStrings()
        let rows = presentation.rows.map { row in
            JSTISystemResourceRow(
                id: strings.add(row.id), title: strings.add(row.title), reason: strings.add(row.reason),
                caption: strings.add(row.caption), release_title: row.releaseTitle.map(strings.add),
                releasing: row.releasing ? 1 : 0
            )
        }
        withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { buffer in
                var view = JSTISystemResourcesView(
                    headline: strings.add(presentation.headline), warning: presentation.warning.map(strings.add),
                    empty: strings.add(presentation.empty), microphone: strings.add(presentation.microphone),
                    rows: buffer.baseAddress, row_count: Int32(buffer.count),
                    can_release_everything: presentation.canReleaseEverything ? 1 : 0
                )
                _ = jsti_window_set_system_resources(&view)
            }
        }
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
