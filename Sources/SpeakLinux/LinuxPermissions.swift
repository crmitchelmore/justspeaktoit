import Foundation
import SpeakCore
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

extension LinuxAppController {
    func permissionItems() -> [DesktopPermissionItem] {
        LinuxPermissions.items(
            session: LinuxHostPlatform.session, output: textOutputOptions(), automation: automationEnabled(),
            runAtLogin: settings.runAtLogin, microphoneWarning: microphoneWarning
        )
    }
}

extension LinuxWindow {
    static func configurePermissions(_ holder: LinuxEventContext) throws {
        guard jsti_permissions_configure(
            linuxPermissionsEvent, Unmanaged.passUnretained(holder).toOpaque()
        ) == 0 else { throw DesktopHostError(message: "Permissions could not be configured.") }
    }

    fileprivate static func showPermissions(_ items: [DesktopPermissionItem], revision: UInt64, hint: String) {
        let strings = Strings()
        let rows = items.map {
            JSTILinuxPermissionRow(
                title: strings.add($0.kind.title), status: strings.add($0.status.label),
                detail: strings.add($0.detail), action: strings.add($0.remediationTitle ?? ""),
                page: $0.remediationTitle == nil ? -1 : Int32(JSTI_PAGE_GENERAL)
            )
        }
        let summary = strings.add(
            "Read-only guidance. This window does not record, send keys, request access or contact a provider. "
                + "Use the controls in General to change app settings; desktop permission grants are managed "
                + "by your desktop.\n\nGlobal dictation shortcut: " + hint
        )
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { jsti_permissions_set_rows($0.baseAddress, $0.count, summary, revision) }
        }
        if result != 0 { LinuxHostPlatform.update("Permissions could not be displayed. Close and reopen it to retry.") }
    }
}

private func linuxPermissionsEvent(_ revision: UInt64, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    holder.enqueueSettings {
        guard jsti_permissions_revision() == revision else { return }
        let items = await holder.controller.permissionItems()
        guard jsti_permissions_revision() == revision else { return }
        LinuxWindow.showPermissions(items, revision: revision, hint: holder.shortcuts.hint)
    }
}
