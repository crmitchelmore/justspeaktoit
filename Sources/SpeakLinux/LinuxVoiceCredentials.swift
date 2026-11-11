import SpeakDesktopHost

// The key editors' state and results are shown by DesktopNativeWindowPlatform.
// swiftlint:disable:next function_parameter_count
func linuxVoiceCredentialEvent(
    _ operation: UnsafePointer<CChar>?, _ purpose: UnsafePointer<CChar>?, _ identifier: UnsafePointer<CChar>?,
    _ requestID: UnsafePointer<CChar>?, _ selectionEpoch: UnsafePointer<CChar>?,
    _ secret: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    LinuxEventContext.voiceCredentialEvent(
        [operation, purpose, identifier, requestID, selectionEpoch, secret], context: context
    )
}
