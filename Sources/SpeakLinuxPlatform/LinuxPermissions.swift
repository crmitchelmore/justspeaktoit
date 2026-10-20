import SpeakCore

/// Passive observations, not a probe or request for microphone/desktop access.
public enum LinuxPermissions {
    public static func items(
        session: LinuxDesktopSession, output: LinuxTextOutputOptions, automation: Bool,
        runAtLogin: Bool?, microphoneWarning: String?
    ) -> [DesktopPermissionItem] {
        [
            microphone(session, warning: microphoneWarning),
            insertion(session, output: output),
            DesktopPermissionItem(
                kind: .automation, status: automation ? .granted : .off,
                detail: automation
                    ? "Local approval allows the speak command to control this app for your account."
                    : "Local command control is off. Imported preferences do not grant local approval.",
                remediationTitle: "Open General"
            ),
            DesktopPermissionItem(
                kind: .notifications, status: .unknown,
                detail: "This desktop does not report a notification permission grant to the app. "
                    + "Check notification settings in your desktop's system settings. "
                    + "Results remain available in the app even when notifications are blocked."
            ),
            DesktopPermissionItem(
                kind: .startup, status: runAtLogin == true ? .unknown : .off,
                detail: runAtLogin == true
                    ? "Launch at login was requested in saved settings. This is not proof that your desktop "
                        + "will launch the app. Review the current Launch at login control in General."
                    : "No launch-at-login request is saved. General shows the current desktop startup control.",
                remediationTitle: "Open General"
            )
        ]
    }

    private static func microphone(_ session: LinuxDesktopSession, warning: String?) -> DesktopPermissionItem {
        let system = session.isGNOME ? "GNOME Settings > Privacy & Security > Microphone"
            : session.isKDE ? "KDE System Settings > Privacy & Security"
            : "your desktop's microphone and application privacy settings"
        let sandbox = session.isFlatpak
            ? " Also review this Flatpak app's audio access in your desktop's application permissions." : ""
        let observed = warning.map { "Observed input-device warning: \($0)\n" } ?? ""
        return DesktopPermissionItem(
            kind: .microphone, status: warning == nil ? .unknown : .warning,
            detail: observed + "Opening this window does not open the microphone. Device discovery is not "
                + "proof of recording permission. If a recording fails, review \(system), "
                + "then choose the intended input in General and try recording again." + sandbox,
            remediationTitle: "Open General"
        )
    }

    private static func insertion(
        _ session: LinuxDesktopSession, output: LinuxTextOutputOptions
    ) -> DesktopPermissionItem {
        guard output.method != .clipboardOnly else {
            return DesktopPermissionItem(
                kind: .textInsertion, status: .notApplicable,
                detail: "Clipboard-only output is selected. No keyboard-injection permission is needed; "
                    + "finished text is copied for you to paste.",
                remediationTitle: "Open General"
            )
        }
        let detail: String
        switch session.displayServer {
        case .x11:
            detail = "An X11 session was detected, not a successful insertion. The app checks the captured "
                + "destination before pasting. If it fails, use clipboard-only output in General. "
                + "This check does not send keys or inspect another app's text."
        case .wayland:
            detail = "Wayland requires your desktop's RemoteDesktop approval for automatic paste. The desktop "
                + "may ask when you first use paste; this window does not request or renew access. "
                + "A portal being installed does not prove permission. Review desktop app permissions "
                + "after denial, or select clipboard-only output in General."
        case .unknown:
            detail = "No supported graphical session was identified. Automatic paste availability is unknown. "
                + "Use clipboard-only output in General and paste the finished text yourself."
        }
        return DesktopPermissionItem(
            kind: .textInsertion, status: .unknown, detail: detail, remediationTitle: "Open General"
        )
    }
}
