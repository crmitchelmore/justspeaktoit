import Foundation
import SpeakCore
import SpeakDesktopHost
import CWindowsSupport

final class WindowsVoiceProviderRegistration: @unchecked Sendable {
    fileprivate var holder: WindowsEventContext?
    fileprivate init(_ holder: WindowsEventContext) { self.holder = holder }
}

private final class WindowsVoiceProviderLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var active: WindowsVoiceProviderRegistration?

    func begin(_ holder: WindowsEventContext) throws -> WindowsVoiceProviderRegistration {
        lock.lock()
        defer { lock.unlock() }
        if let active { try endLocked(active) }
        let registration = WindowsVoiceProviderRegistration(holder)
        guard jsti_window_set_voice_provider_credential_handler(
            windowsVoiceProviderCredentialEvent, Unmanaged.passUnretained(registration).toOpaque()) == 0 else {
            throw DesktopHostError(message: "The account Voice key callback could not be configured.")
        }
        active = registration
        return registration
    }

    func end(_ registration: WindowsVoiceProviderRegistration) throws {
        lock.lock()
        defer { lock.unlock() }
        try endLocked(registration)
    }

    private func endLocked(_ registration: WindowsVoiceProviderRegistration) throws {
        guard active === registration else { return }
        // Callback forwarding never takes this lifecycle lock or awaits work.
        guard jsti_window_set_voice_provider_credential_handler(nil, nil) == 0 else {
            throw DesktopHostError(message: "The account Voice key callback could not be detached safely.")
        }
        active = nil
        registration.holder = nil
    }
}

extension WindowsNative {
    private static let providerLifecycle = WindowsVoiceProviderLifecycle()

    static func beginVoiceProviderCallbacks(_ holder: WindowsEventContext) throws -> WindowsVoiceProviderRegistration {
        try providerLifecycle.begin(holder)
    }

    static func endVoiceProviderCallbacks(_ registration: WindowsVoiceProviderRegistration) {
        do { try providerLifecycle.end(registration) } catch { update(error.localizedDescription) }
    }
}

extension WindowsHostPlatform {
    package static func voiceAccountProviders(_ presentation: DesktopVoiceAccountProvidersPresentation) {
        let providers = presentation.providers
        let selected = providers.firstIndex(of: presentation.context.provider).map(Int32.init) ?? -1
        if jsti_window_set_voice_account_providers(
            presentation.context.sessionID.uuidString, presentation.context.epoch.uuidString,
            providers.map(\.id).joined(separator: "\n"),
            providers.map(\.displayName).joined(separator: "\n"), selected) < 0 {
            WindowsNative.update("The account Voice providers could not be shown.")
        }
    }
}

// swiftlint:disable:next function_parameter_count
func windowsVoiceProviderCredentialEvent(
    _ operation: UnsafePointer<CChar>?, _ purpose: UnsafePointer<CChar>?, _ providerID: UnsafePointer<CChar>?,
    _ identifier: UnsafePointer<CChar>?, _ session: UnsafePointer<CChar>?, _ epoch: UnsafePointer<CChar>?,
    _ requestID: UnsafePointer<CChar>?, _ secret: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let registration = Unmanaged<WindowsVoiceProviderRegistration>.fromOpaque(context).takeUnretainedValue()
    guard let holder = registration.holder else { return }
    do {
        let message = try VoiceProviderCredentialMessage(
            operation: operation.map(String.init(cString:)) ?? "",
            purpose: purpose.map(String.init(cString:)) ?? "",
            providerID: providerID.map(String.init(cString:)) ?? "",
            identifier: identifier.map(String.init(cString:)) ?? "",
            sessionID: session.map(String.init(cString:)) ?? "",
            epoch: epoch.map(String.init(cString:)) ?? "",
            requestID: requestID.map(String.init(cString:)) ?? "",
            key: secret.map(String.init(cString:)) ?? "")
        holder.enqueueSettings { await holder.controller.handleVoiceProviderCredential(message) }
    } catch { WindowsNative.update(error.localizedDescription) }
}
