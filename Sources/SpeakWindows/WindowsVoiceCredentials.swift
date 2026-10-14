import Foundation
import SpeakCore
import SpeakDesktopHost
import CWindowsSupport

extension WindowsHostPlatform {
    package static func voiceCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>, requestID: UUID
    ) {
        let view = DesktopVoiceCredentialView(result, requestID: requestID, credentialStore: credentialStoreName)
        if jsti_window_set_voice_credential(
            view.requestID, view.selectionEpoch, view.identifier, view.label, view.privacy, view.status,
            view.saved, view.canSave) < 0 {
            WindowsNative.update("The Voice provider key state could not be shown.")
        }
    }

    package static func voiceCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceOutputCredentialRequest
    ) {
        let message: String
        let success: Int32
        switch result {
        case .success:
            success = 1
            message = request.operation == .remove
                ? "The saved provider key was removed." : "The provider key was saved."
        case .failure(let error):
            success = 0
            message = error.localizedDescription
        }
        if jsti_window_finish_voice_credential(
            request.id.uuidString, request.selectionEpoch.uuidString, success, message) < 0 {
            WindowsNative.update("The Voice provider key operation result could not be shown.")
        }
    }
}

// swiftlint:disable:next function_parameter_count
func windowsVoiceCredentialEvent(
    _ operation: UnsafePointer<CChar>?, _ purpose: UnsafePointer<CChar>?, _ identifier: UnsafePointer<CChar>?,
    _ requestID: UnsafePointer<CChar>?, _ selectionEpoch: UnsafePointer<CChar>?,
    _ secret: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    do {
        let message = try VoiceOutputCredentialMessage(
            operation: operation.map(String.init(cString:)) ?? "",
            purpose: purpose.map(String.init(cString:)) ?? "",
            identifier: identifier.map(String.init(cString:)) ?? "",
            requestID: requestID.map(String.init(cString:)) ?? "",
            selectionEpoch: selectionEpoch.map(String.init(cString:)) ?? "",
            key: secret.map(String.init(cString:)) ?? "")
        holder.enqueueSettings { await holder.controller.handleVoiceCredential(message) }
    } catch { WindowsNative.update(error.localizedDescription) }
}
