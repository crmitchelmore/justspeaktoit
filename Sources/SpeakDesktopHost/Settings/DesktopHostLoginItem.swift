import Foundation
import SpeakDesktop

extension DesktopHostController {
    /// Shows General › Launch at login as the system has it now, so a change
    /// made in the system's startup settings shows too.
    @discardableResult
    package func refreshLoginItem() async -> DesktopLoginItemState {
        let state = await Platform.loginItemState(recorded: settings.runAtLogin)
        Platform.showLoginItem(
            state, detail: DesktopLoginItem.detail(state, systemSettings: Platform.loginItemSettingsName)
        )
        return state
    }

    /// The switch: registers or removes the login item, then shows the state
    /// the system reached, which a policy or the user's system settings may
    /// have kept from changing.
    @discardableResult
    package func setLaunchAtLogin(_ enabled: Bool) async -> DesktopLoginItemState {
        guard !closed else { return .unavailable }
        let reached: DesktopLoginItemState
        do {
            reached = try await Platform.setLoginItem(enabled)
        } catch {
            update("Could not change \(DesktopLoginItem.title): \(error.localizedDescription)")
            return await refreshLoginItem()
        }
        let systemSettings = Platform.loginItemSettingsName
        Platform.showLoginItem(reached, detail: DesktopLoginItem.detail(reached, systemSettings: systemSettings))
        update(DesktopLoginItem.status(reached, systemSettings: systemSettings))
        recordLoginItem(reached)
        return reached
    }

    private func recordLoginItem(_ state: DesktopLoginItemState) {
        guard !closed, state != .unavailable, settings.runAtLogin != state.launchesAtLogin else { return }
        var changed = settings
        changed.runAtLogin = state.launchesAtLogin
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
        } catch { update("Could not save \(DesktopLoginItem.title): \(error.localizedDescription)") }
    }
}
