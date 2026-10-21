import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

final class LinuxGlobalActionCallback: @unchecked Sendable {
    private weak var holder: LinuxEventContext?
    private weak var lifetime: DesktopShortcutListenerLifetime?
    private weak var owner: LinuxGlobalActionShortcuts?
    private let actions: [Int32: DesktopShortcutAction]

    init(
        holder: LinuxEventContext, lifetime: DesktopShortcutListenerLifetime,
        entries: [DesktopLinuxGlobalShortcutPlan.Entry], owner: LinuxGlobalActionShortcuts
    ) {
        self.holder = holder
        self.lifetime = lifetime
        self.owner = owner
        actions = Dictionary(uniqueKeysWithValues: entries.map { ($0.identifier, $0.action) })
    }

    func receive(_ identifier: Int32) {
        guard let lifetime, lifetime.acceptsCallbacks else { return }
        if identifier == -1 { owner?.lost(lifetime, callback: self); return }
        guard let holder, jsti_action_shortcuts_editor_is_open() == 0, jsti_api_keys_is_open() == 0 else { return }
        guard let action = actions[identifier] else {
            LinuxHostPlatform.update("The X11 listener supplied an unknown action shortcut.")
            return
        }
        switch LinuxActionShortcutRun(action) {
        case .record: holder.shortcutToggle(modelIndex: nil, deviceID: nil, lifetime: lifetime)
        case .clipboard:
            lifetime.admitCallback {
                holder.enqueueSettings { await holder.controller.readClipboardAloud() }
            }
        case .pasteLastHistory: holder.pasteLastHistory(lifetime: lifetime)
        case .selectedText: holder.speakSelectedText(lifetime: lifetime)
        default:
            LinuxHostPlatform.update("The X11 action shortcut has no supported execution route.")
        }
    }

    func refresh() {
        guard let holder, let lifetime else { return }
        holder.enqueueSettings {
            // A failed registration may publish its reason, but a retired one cannot.
            guard lifetime.publish({}) else { return }
            do { try await LinuxWindow.configureActionShortcuts(holder) } catch {
                LinuxHostPlatform.update(
                    "Could not display global shortcut availability: \(error.localizedDescription)"
                )
            }
        }
    }
}

func linuxGlobalActionPressed(_ identifier: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LinuxGlobalActionCallback>.fromOpaque(context).takeUnretainedValue().receive(identifier)
}
