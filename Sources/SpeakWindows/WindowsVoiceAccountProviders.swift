import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

typealias WindowsVoiceProviderRegistration = NativeCallbackContext<WindowsEventContext>

extension WindowsNative {
    private static let providerCallbacks = DesktopNativeHandlerSlot<WindowsEventContext>(
        "The account Voice key callback"
    ) { context in
        guard let context else { return jsti_window_set_voice_provider_credential_handler(nil, nil) == 0 }
        return jsti_window_set_voice_provider_credential_handler(windowsVoiceProviderCredentialEvent, context) == 0
    }

    static func beginVoiceProviderCallbacks(_ holder: WindowsEventContext) throws -> WindowsVoiceProviderRegistration {
        try providerCallbacks.begin(holder)
    }

    static func endVoiceProviderCallbacks(_ registration: WindowsVoiceProviderRegistration) {
        providerCallbacks.end(registration)
    }
}

// The account key editor's state and results are shown by DesktopNativeWindowPlatform.
// swiftlint:disable:next function_parameter_count
func windowsVoiceProviderCredentialEvent(
    _ operation: UnsafePointer<CChar>?, _ purpose: UnsafePointer<CChar>?, _ providerID: UnsafePointer<CChar>?,
    _ identifier: UnsafePointer<CChar>?, _ session: UnsafePointer<CChar>?, _ epoch: UnsafePointer<CChar>?,
    _ requestID: UnsafePointer<CChar>?, _ secret: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    WindowsEventContext.voiceProviderCredentialEvent(
        [operation, purpose, providerID, identifier, session, epoch, requestID, secret], context: context
    )
}
