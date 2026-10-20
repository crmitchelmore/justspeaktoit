import Foundation
import SpeakCore
import SpeakDesktopHost
import CLinuxSupport

final class LinuxActionShortcutEditorState: @unchecked Sendable {
    static let shared = LinuxActionShortcutEditorState()
    private let lock = NSLock()
    private var revision = UUID()
    private var bindings = DesktopShortcutBindings.defaults

    func configure(_ value: DesktopShortcutBindings) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if value != bindings { revision = UUID(); bindings = value }
        return revision
    }

    func snapshot(_ revision: UUID) -> DesktopShortcutBindings? {
        lock.lock()
        defer { lock.unlock() }
        return self.revision == revision ? bindings : nil
    }
}

private func shortcutEditFinished(_ request: UUID?, success: Bool, message: String) {
    let result = (request?.uuidString ?? "").withCString { request in
        message.withCString { jsti_action_shortcuts_edit_finished(request, success ? 1 : 0, $0) }
    }
    if result != 0 { LinuxHostPlatform.update("The action shortcut editor could not show its save result.") }
}

func linuxActionShortcutEdit(_ wire: String, holder: LinuxEventContext) {
    let request: DesktopHostLinuxShortcutRequest
    do {
        request = try DesktopHostLinuxShortcutRequest(wire: wire)
    } catch {
        let header = wire.prefix(80).split(separator: "\n").first?.split(separator: "\t")
        let id = header.flatMap { $0.count == 2 ? UUID(uuidString: String($0[1])) : nil }
        shortcutEditFinished(id, success: false, message: error.localizedDescription)
        LinuxHostPlatform.update(error.localizedDescription)
        return
    }
    guard let base = LinuxActionShortcutEditorState.shared.snapshot(request.revision) else {
        shortcutEditFinished(
            request.request, success: false,
            message: "Saved shortcuts changed. Close and reopen this editor before saving."
        )
        return
    }
    let globals = Dictionary(uniqueKeysWithValues: request.rows.map { ($0.action, $0.isGlobal) })
    let runnable = Set(DesktopShortcutAction.allCases.filter { LinuxActionShortcutRun($0) != .unavailable })
    let edit = base.editingLinux(
        request.rows, runnable: runnable,
        blocking: { action, chord in
            guard globals[action] != true else { return nil }
            let dictation = DesktopShortcutLinuxChord(keysym: 0x20, modifiers: 12)
            return chord == dictation ? "the Linux dictation shortcut" : nil
        },
        warning: { action, chord in
            guard globals[action] != true, chord.modifiers == DesktopShortcutLinuxChord.control,
                  let sidebar = DesktopSidebarShortcut.allCases.first(where: {
                      chord.keysym == UInt32(0x30 + $0.digit)
                  }), LinuxActionShortcutRun(action) != .page(sidebar.rawValue) else { return nil }
            return "the \(sidebar.rawValue) sidebar shortcut"
        }
    )
    switch edit {
    case .refused(let reason):
        shortcutEditFinished(request.request, success: false, message: reason)
    case .accepted(let bindings, let warnings):
        holder.enqueueSettings {
            await saveLinuxActionShortcuts(
                bindings, replacing: base, warnings: warnings, request: request.request, holder: holder
            )
        }
    }
}

private func saveLinuxActionShortcuts(
    _ bindings: DesktopShortcutBindings,
    replacing base: DesktopShortcutBindings,
    warnings: [String],
    request: UUID,
    holder: LinuxEventContext
) async {
    do {
        try await holder.controller.saveShortcutBindings(bindings, replacing: base)
    } catch {
        shortcutEditFinished(request, success: false, message: error.localizedDescription)
        LinuxHostPlatform.update("Could not save action shortcuts: \(error.localizedDescription)")
        return
    }
    do {
        try await LinuxWindow.configureActionShortcuts(holder)
    } catch {
        if jsti_window_set_action_shortcuts(nil, 0) != 0 {
            LinuxHostPlatform.update("Saved shortcuts could not be activated or disabled safely.")
        }
        let message = "Shortcuts were saved but could not be activated: \(error.localizedDescription)"
        shortcutEditFinished(request, success: false, message: message)
        LinuxHostPlatform.update(message)
        return
    }
    let message = warnings.isEmpty ? "Action shortcuts saved." : warnings.prefix(3).joined(separator: "\n")
    shortcutEditFinished(request, success: true, message: message)
    LinuxHostPlatform.update(message)
}
