import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

typealias LinuxVoiceProviderRegistration = NativeCallbackContext<LinuxEventContext>

extension LinuxWindow {
    private static let providerCallbacks = DesktopNativeHandlerSlot<LinuxEventContext>(
        "The account Voice key callback"
    ) { context in
        guard let context else { return jsti_window_set_voice_provider_credential_handler(nil, nil) == 0 }
        return jsti_window_set_voice_provider_credential_handler(linuxVoiceProviderCredentialEvent, context) == 0
    }

    static func beginVoiceProviderCallbacks(_ holder: LinuxEventContext) throws -> LinuxVoiceProviderRegistration {
        try providerCallbacks.begin(holder)
    }

    static func endVoiceProviderCallbacks(_ registration: LinuxVoiceProviderRegistration) {
        providerCallbacks.end(registration)
    }
}

// The account key editor's state and results are shown by DesktopNativeWindowPlatform.
// swiftlint:disable:next function_parameter_count
func linuxVoiceProviderCredentialEvent(
    _ operation: UnsafePointer<CChar>?, _ purpose: UnsafePointer<CChar>?, _ providerID: UnsafePointer<CChar>?,
    _ identifier: UnsafePointer<CChar>?, _ session: UnsafePointer<CChar>?, _ epoch: UnsafePointer<CChar>?,
    _ requestID: UnsafePointer<CChar>?, _ secret: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    LinuxEventContext.voiceProviderCredentialEvent(
        [operation, purpose, providerID, identifier, session, epoch, requestID, secret], context: context
    )
}
