import Foundation
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

/// Edit Selection by Voice on Linux: the selection-access session's admitted
/// AT-SPI field is captured when the command runs, and only that same field,
/// selection and text are replaced; otherwise the rewrite is copied instead.
enum LinuxVoiceEdit {
    static func source(target: LinuxVoiceEditTarget?, executablePath: String?) -> DesktopHostVoiceEditSource {
        let unavailable = LinuxVoiceEditTarget.availability
        return DesktopHostVoiceEditSource(
            executablePath: executablePath,
            capture: { try await DesktopVoiceEditDelivery.capture(target, unavailable: unavailable) },
            replace: { text in
                switch try await DesktopVoiceEditDelivery.replace(text, target: target, unavailable: unavailable) {
                case .replaced(let status): return .replaced(status)
                case .recovery(let status): return .recovery(status)
                }
            },
            cancel: { target?.cancel() }
        )
    }

    /// The per-app profile key, as dictation reads it: X11 outside Flatpak only.
    static func executablePath() async -> String? {
        guard LinuxHostPlatform.session.canUseX11Injection, !LinuxSandbox.isFlatpak else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? LinuxX11.captureTargetChecked()?.executablePath
        }.value
    }
}

extension LinuxEventContext {
    func toggleVoiceEdit(lifetime: DesktopShortcutListenerLifetime? = nil) {
        // Captured before any queue hop, so a later focus change cannot retarget it.
        let target = LinuxVoiceEditTarget.captureAdmitted()
        let deliver = {
            self.enqueueSettings {
                var path: String?
                if target != nil { path = await LinuxVoiceEdit.executablePath() }
                let source = LinuxVoiceEdit.source(target: target, executablePath: path)
                let deviceID = await self.controller.selectedMicrophone()
                await self.controller.toggleVoiceEdit(source: source, deviceID: deviceID)
            }
        }
        if let lifetime { lifetime.admitCallback(deliver) } else { deliver() }
    }
}
