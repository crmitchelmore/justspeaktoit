import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost

/// General › Launch at login: the HKCU Run value for the portable app, the
/// declared startup task for the MSIX app (WindowsLoginItem.cpp).
extension WindowsHostPlatform {
    static var loginItemSettingsName: String { "Settings › Apps › Startup" }

    static func loginItemState(recorded: Bool?) async -> DesktopLoginItemState {
        await offThread { DesktopLoginItemState(rawValue: jsti_login_item_state()) ?? .unavailable }
    }

    static func setLoginItem(_ enabled: Bool) async throws -> DesktopLoginItemState {
        try await offThread {
            var reached: Int32 = 0
            try WindowsNative.checked { jsti_login_item_set(enabled ? 1 : 0, &reached, $0, $1) }
            return DesktopLoginItemState(rawValue: reached) ?? .unavailable
        }
    }

    static func showLoginItem(_ state: DesktopLoginItemState, detail: String) {
        _ = jsti_window_set_login_item(state.rawValue, detail)
    }

    /// The registry and the startup task API can wait on the system; keep
    /// them off the cooperative pool and the UI thread.
    private static func offThread<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try work() }) }.start()
        }
    }

    private static func offThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: work()) }.start()
        }
    }
}
