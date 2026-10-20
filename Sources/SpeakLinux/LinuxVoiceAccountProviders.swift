import Foundation
import SpeakCore
import SpeakDesktopHost
import CLinuxSupport

final class LinuxVoiceProviderRegistration: @unchecked Sendable {
    fileprivate var holder: LinuxEventContext?
    fileprivate init(_ holder: LinuxEventContext) { self.holder = holder }
}

private final class LinuxVoiceProviderLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var active: LinuxVoiceProviderRegistration?

    func begin(_ holder: LinuxEventContext) throws -> LinuxVoiceProviderRegistration {
        lock.lock()
        defer { lock.unlock() }
        if let active { try endLocked(active) }
        let registration = LinuxVoiceProviderRegistration(holder)
        guard jsti_window_set_voice_provider_credential_handler(
            linuxVoiceProviderCredentialEvent, Unmanaged.passUnretained(registration).toOpaque()) == 0 else {
            throw DesktopHostError(message: "The account Voice key callback could not be configured.")
        }
        active = registration
        return registration
    }

    func end(_ registration: LinuxVoiceProviderRegistration) throws {
        lock.lock()
        defer { lock.unlock() }
        try endLocked(registration)
    }

    private func endLocked(_ registration: LinuxVoiceProviderRegistration) throws {
        guard active === registration else { return }
        // Callback forwarding never takes this lifecycle lock or awaits work.
        guard jsti_window_set_voice_provider_credential_handler(nil, nil) == 0 else {
            throw DesktopHostError(message: "The account Voice key callback could not be detached safely.")
        }
        active = nil
        registration.holder = nil
    }
}

extension LinuxWindow {
    private static let providerLifecycle = LinuxVoiceProviderLifecycle()

    static func beginVoiceProviderCallbacks(_ holder: LinuxEventContext) throws -> LinuxVoiceProviderRegistration {
        try providerLifecycle.begin(holder)
    }

    static func endVoiceProviderCallbacks(_ registration: LinuxVoiceProviderRegistration) {
        do { try providerLifecycle.end(registration) } catch { LinuxHostPlatform.update(error.localizedDescription) }
    }
}

extension LinuxHostPlatform {
    package static func voiceAccountProviders(_ presentation: DesktopVoiceAccountProvidersPresentation) {
        let providers = presentation.providers
        let selected = providers.firstIndex(of: presentation.context.provider).map(Int32.init) ?? -1
        if jsti_window_set_voice_account_providers(
            presentation.context.sessionID.uuidString, presentation.context.epoch.uuidString,
            providers.map(\.id).joined(separator: "\n"),
            providers.map(\.displayName).joined(separator: "\n"), selected) < 0 {
            update("The account Voice providers could not be shown.")
        }
    }
}

// swiftlint:disable:next function_parameter_count
func linuxVoiceProviderCredentialEvent(
    _ operation: UnsafePointer<CChar>?, _ purpose: UnsafePointer<CChar>?, _ providerID: UnsafePointer<CChar>?,
    _ identifier: UnsafePointer<CChar>?, _ session: UnsafePointer<CChar>?, _ epoch: UnsafePointer<CChar>?,
    _ requestID: UnsafePointer<CChar>?, _ secret: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let registration = Unmanaged<LinuxVoiceProviderRegistration>.fromOpaque(context).takeUnretainedValue()
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
    } catch { LinuxHostPlatform.update(error.localizedDescription) }
}
