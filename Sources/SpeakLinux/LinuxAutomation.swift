import Foundation
import SpeakCore
import SpeakDesktopHost
import SpeakLinuxAutomation
import CLinuxSupport

/// Owns only the Linux endpoint's lifecycle. Commands are the same shared
/// DesktopHostController pathways, not another GTK command switch.
final class LinuxAutomationSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var server: LinuxAutomationServer?
    private let controller: LinuxAppController

    init(controller: LinuxAppController) { self.controller = controller }

    private func apply(enabled: Bool) -> (Bool, String) {
        lock.withLock {
            if enabled, server?.isRunning == true {
                return (true, "Automation is on. The speak command can control this app for your Linux account.")
            }
            server?.stop()
            server = nil
            guard enabled else { return (false, "Automation is off. The speak command cannot reach this app.") }
            do {
                let created = LinuxAutomationServer(onFailure: {
                    Self.publish(
                        false, "Automation stopped after a listener failure. Disable and enable it to retry."
                    )
                })
                let controller = controller
                try created.start { request in
                    await AutomationCommandDispatcher.response(to: request, host: controller)
                }
                server = created
                return (true, "Automation is on. The speak command can control this app for your Linux account.")
            } catch {
                return (false, "Automation could not start: \(error.localizedDescription)")
            }
        }
    }

    /// Native stop interrupts and joins all owned IO workers on this dedicated
    /// thread, not GTK, the settings queue executor or the cooperative pool.
    func applyOffThread(enabled: Bool) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            Thread { [self] in continuation.resume(returning: apply(enabled: enabled)) }.start()
        }
    }

    private func publishActual(_ detail: String) {
        lock.withLock {
            let running = server?.isRunning == true
            let message: String
            if running {
                message = "Automation is on. The speak command can control this app for your Linux account."
            } else if detail.hasPrefix("Automation is on.") {
                message = "Automation stopped after a listener failure. Disable and enable it to retry."
            } else {
                message = detail
            }
            Self.publish(running, message)
        }
    }

    private func presentOffThread(_ detail: String) async {
        await withCheckedContinuation { continuation in
            Thread { [self] in publishActual(detail); continuation.resume() }.start()
        }
    }

    static func reconcile(_ holder: LinuxEventContext) async {
        let allowed = await holder.controller.automationEnabled()
        let (running, detail) = await holder.automation.applyOffThread(enabled: allowed)
        let description: String
        if allowed { description = detail } else {
            description = await holder.controller.automationPreferenceDescription()
        }
        await holder.automation.presentOffThread(description)
        if allowed && !running { await holder.controller.update(description) }
    }

    static func restore(_ holder: LinuxEventContext) async {
        await holder.controller.setAutomationPreferenceHandler { [weak holder] in
            guard let holder else { return }
            await reconcile(holder)
        }
        await reconcile(holder)
    }

    static func setEnabled(_ enabled: Bool, holder: LinuxEventContext) async {
        // Revoke access before persisting an off choice. On write failure the
        // endpoint remains off, and the failure explicitly names the saved state.
        if !enabled { _ = await holder.automation.applyOffThread(enabled: false) }
        do {
            try await holder.controller.saveAutomationPreference(enabled: enabled)
            await reconcile(holder)
        } catch {
            let detail = "Automation is off. Could not save the preference: \(error.localizedDescription)"
            _ = await holder.automation.applyOffThread(enabled: false)
            publish(false, detail)
            await holder.controller.update(detail)
        }
    }

    private static func publish(_ enabled: Bool, _ detail: String) {
        if jsti_window_set_automation(enabled ? 1 : 0, detail) != 0 {
            FileHandle.standardError.write(Data("Could not display the automation service state.\n".utf8))
        }
    }
}
