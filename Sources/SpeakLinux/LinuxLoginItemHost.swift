import Foundation
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// General › Launch at login: the XDG autostart entry, or the Background
/// portal inside Flatpak (see `LinuxLoginItem`).
extension LinuxHostPlatform {
    static var loginItemSettingsName: String {
        session.isGNOME ? "Settings › Apps › Just Speak to It" : "your desktop's app permissions"
    }

    static func loginItemState(recorded: Bool?) async -> DesktopLoginItemState {
        guard session.isFlatpak else { return LinuxLoginItem.state() }
        guard await offThread({ LinuxLoginItem.portalAvailable }) else { return .unavailable }
        return recorded == true ? .enabled : .disabled
    }

    static func setLoginItem(_ enabled: Bool) async throws -> DesktopLoginItemState {
        let executable = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        guard session.isFlatpak else { return try LinuxLoginItem.setEnabled(enabled, executable: executable) }
        let command = URL(fileURLWithPath: executable).lastPathComponent
        return try await offThread { try LinuxLoginItem.requestThroughPortal(enabled, command: command) }
    }

    static func showLoginItem(_ state: DesktopLoginItemState, detail: String) {
        _ = jsti_window_set_login_item(state.rawValue, detail)
    }

    /// The portal blocks while the desktop asks the user; keep it off the
    /// cooperative pool.
    private static func offThread<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func offThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: work()) }
        }
    }
}
