import Foundation
import CWindowsSupport
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

/// Windows' own permission switches, read from the registry and the process
/// token without prompting. Each value is 1 allowed or on, 0 denied or off,
/// and -1 when Windows does not say.
struct WindowsSystemPermissions: Equatable, Sendable {
    var microphoneDevice: Int32 = -1
    var microphoneUser: Int32 = -1
    var microphoneApp: Int32 = -1
    var microphonePolicy: Int32 = -1
    var packaged = false
    var elevated: Int32 = -1
    var notifications: Int32 = -1

    static func read() -> WindowsSystemPermissions {
        var native = JSTISystemPermissions()
        guard jsti_system_permissions(&native) == 0 else { return WindowsSystemPermissions() }
        return WindowsSystemPermissions(
            microphoneDevice: native.microphone_device, microphoneUser: native.microphone_user,
            microphoneApp: native.microphone_app, microphonePolicy: native.microphone_policy,
            packaged: native.packaged == 1, elevated: native.elevated, notifications: native.notifications
        )
    }
}

/// A Permissions page row: the shared item and the page its button opens.
struct WindowsPermissionRow: Equatable, Sendable {
    var item: DesktopPermissionItem
    /// A `JSTISettingsPage`.
    var page: Int32

    init(_ item: DesktopPermissionItem, page: JSTISettingsPage = JSTI_SETTINGS_NONE) {
        self.item = item
        self.page = Int32(page.rawValue)
    }
}

/// The Windows Permissions page, the Mac's Permissions settings and recovery
/// help for this host: what Windows allows, in plain language, with the
/// settings page that changes it.
enum WindowsPermissions {
    /// Every row from observed state; pure, so the wording is testable.
    static func rows(
        system: WindowsSystemPermissions, textOutput: WindowsTextOutputOptions.Method,
        automation: Bool, loginItem: DesktopLoginItemState
    ) -> [WindowsPermissionRow] {
        [
            microphone(system), insertion(textOutput), elevation(system),
            WindowsPermissionRow(DesktopPermissionItem(
                kind: .automation, status: automation ? .granted : .off,
                detail: automation ? "The speak command can control this app." : "Automation is off.",
                remediationTitle: "Open General settings"
            ), page: JSTI_SETTINGS_GENERAL),
            notifications(system), startup(loginItem)
        ]
    }

    static func microphone(_ system: WindowsSystemPermissions) -> WindowsPermissionRow {
        let blocked: String?
        if system.microphonePolicy == 0 {
            blocked = "Your organisation's policy blocks apps from using the microphone."
        } else if system.microphoneDevice == 0 {
            blocked = "Microphone access is off for this device. An administrator can turn it on."
        } else if system.microphoneUser == 0 {
            blocked = "Microphone access is off in Windows privacy settings."
        } else if system.microphoneApp == 0 {
            blocked = system.packaged
                ? "Microphone access is off for Just Speak to It in Windows privacy settings."
                : "\"Let desktop apps access your microphone\" is off in Windows privacy settings."
        } else {
            blocked = nil
        }
        let status: DesktopPermissionStatus
        let detail: String
        if let blocked {
            (status, detail) = (.denied, blocked)
        } else if system.microphoneUser == 1 || system.microphoneApp == 1 {
            (status, detail) = (.granted, "Windows lets this app use the microphone.")
        } else {
            (status, detail) = (.unknown, "Windows did not report microphone access. Try a test recording.")
        }
        return WindowsPermissionRow(DesktopPermissionItem(
            kind: .microphone, status: status, detail: detail,
            remediationTitle: "Open microphone privacy settings"
        ), page: JSTI_SETTINGS_MICROPHONE)
    }

    static func insertion(_ method: WindowsTextOutputOptions.Method) -> WindowsPermissionRow {
        let detail = switch method {
        case .smart: "Text is typed where you were working, or pasted when an app does not accept typing."
        case .directOnly: "Text is typed where you were working; it is never pasted."
        case .clipboardOnly: "Text output is set to copy only, so finished text is copied for you to paste."
        }
        return WindowsPermissionRow(DesktopPermissionItem(
            kind: .textInsertion, status: method == .clipboardOnly ? .notApplicable : .granted,
            detail: detail, remediationTitle: "Text output..."
        ), page: JSTI_SETTINGS_TEXT_OUTPUT)
    }

    static func elevation(_ system: WindowsSystemPermissions) -> WindowsPermissionRow {
        let item = switch system.elevated {
        case 1: DesktopPermissionItem(
            kind: .elevation, status: .warning,
            detail: "Just Speak to It is running as administrator. Start it normally unless you dictate into "
                + "administrator apps; the shortcut and typing then match those apps only."
        )
        case 0: DesktopPermissionItem(
            kind: .elevation, status: .notApplicable,
            detail: "Apps running as administrator can't receive typed text; it is copied for you to paste instead."
        )
        default: DesktopPermissionItem(
            kind: .elevation, status: .unknown, detail: "Windows did not say whether this app is elevated."
        )
        }
        return WindowsPermissionRow(item)
    }

    static func notifications(_ system: WindowsSystemPermissions) -> WindowsPermissionRow {
        let state = switch system.notifications {
        case 1: " Windows notifications are on."
        case 0: " Windows notifications are off."
        default: ""
        }
        return WindowsPermissionRow(DesktopPermissionItem(
            kind: .notifications, status: .notApplicable,
            detail: "Progress shows in the app window, the recording overlay and the notification area icon, so "
                + "the app does not need notifications." + state,
            remediationTitle: "Open notification settings"
        ), page: JSTI_SETTINGS_NOTIFICATIONS)
    }

    static func startup(_ state: DesktopLoginItemState) -> WindowsPermissionRow {
        let detail = DesktopLoginItem.detail(state, systemSettings: WindowsHostPlatform.loginItemSettingsName)
        switch state {
        case .enabled, .enabledBySystem:
            return WindowsPermissionRow(DesktopPermissionItem(kind: .startup, status: .granted, detail: detail))
        case .disabled:
            return WindowsPermissionRow(DesktopPermissionItem(
                kind: .startup, status: .off, detail: detail, remediationTitle: "Open General settings"
            ), page: JSTI_SETTINGS_GENERAL)
        case .disabledBySystem:
            return WindowsPermissionRow(DesktopPermissionItem(
                kind: .startup, status: .denied, detail: detail, remediationTitle: "Open startup apps settings"
            ), page: JSTI_SETTINGS_STARTUP_APPS)
        case .unavailable:
            return WindowsPermissionRow(DesktopPermissionItem(kind: .startup, status: .notApplicable, detail: detail))
        }
    }

    /// Reads everything the page shows, in settings order so a just-applied
    /// text output choice is reflected.
    static func check(_ holder: WindowsEventContext) async -> [WindowsPermissionRow] {
        let controller = holder.controller
        let system = await Task.detached { WindowsSystemPermissions.read() }.value
        let method = await controller.textOutputOptions().method
        let automation = await controller.automationEnabled()
        let loginItem = await controller.refreshLoginItem()
        return rows(system: system, textOutput: method, automation: automation, loginItem: loginItem)
    }

    /// The dashboard warning before the first ready status; system state only,
    /// so it never waits on settings.
    static func prepareWarning(_ holder: WindowsEventContext) async {
        let system = await Task.detached { WindowsSystemPermissions.read() }.value
        let method = await holder.controller.textOutputOptions().method
        await holder.controller.setPermissionWarning([microphone(system).item, insertion(method).item])
    }

    static func show(_ rows: [WindowsPermissionRow], summary: String) {
        var strings: [String] = []
        for row in rows {
            strings += [
                row.item.kind.title, row.item.status.label, row.item.detail, row.item.kind.guidance,
                row.item.remediationTitle ?? ""
            ]
        }
        let result = withCStrings(strings + [summary]) { pointers -> Int32 in
            let native = rows.indices.map { index -> JSTIPermissionRow in
                let base = index * 5
                return JSTIPermissionRow(
                    title: pointers[base], status: pointers[base + 1], detail: pointers[base + 2],
                    guidance: pointers[base + 3], remediation: pointers[base + 4],
                    settings_page: rows[index].page, blocking: rows[index].item.isBlocking ? 1 : 0
                )
            }
            return native.withUnsafeBufferPointer {
                jsti_permissions_set_rows($0.baseAddress, $0.count, pointers[pointers.count - 1])
            }
        }
        if result != 0 { WindowsNative.update("Could not show the permission checks.") }
    }
}

/// Opened, Check again, or back from a Windows Settings page: on the UI thread.
func permissionsEvent(_ command: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context, command == Int32(JSTI_PERMISSIONS_COMMAND_CHECK.rawValue) else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    holder.enqueueSettings {
        let rows = await WindowsPermissions.check(holder)
        let items = rows.map(\.item)
        let summary = DesktopPermissionSummary.recheckMessage(items)
        WindowsPermissions.show(rows, summary: summary)
        await holder.controller.setPermissionWarning(items)
        WindowsNative.update(DesktopPermissionSummary.blockingMessage(items) ?? summary)
    }
}

extension WindowsEventContext {
    func configurePermissions() {
        _ = jsti_permissions_configure(permissionsEvent, Unmanaged.passUnretained(self).toOpaque())
    }
}
