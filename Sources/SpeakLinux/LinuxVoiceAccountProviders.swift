import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

typealias LinuxVoiceProviderRegistration = NativeCallbackContext<LinuxEventContext>

extension LinuxWindow {
    private static let providerCallbacks = NativeCallbackSlot<LinuxEventContext> { context in
        guard let context else { return jsti_window_set_voice_provider_credential_handler(nil, nil) == 0 }
        return jsti_window_set_voice_provider_credential_handler(linuxVoiceProviderCredentialEvent, context) == 0
    }

    static func beginVoiceProviderCallbacks(_ holder: LinuxEventContext) throws -> LinuxVoiceProviderRegistration {
        guard let registration = providerCallbacks.begin(holder) else {
            throw DesktopHostError(message: "The account Voice key callback could not be configured.")
        }
        return registration
    }

    static func endVoiceProviderCallbacks(_ registration: LinuxVoiceProviderRegistration) {
        // Callback forwarding never takes the slot's lock or awaits work.
        if !providerCallbacks.end(registration) {
            LinuxHostPlatform.update("The account Voice key callback could not be detached safely.")
        }
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
    guard let holder = NativeCallbackContext<LinuxEventContext>.resolve(context) else { return }
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
