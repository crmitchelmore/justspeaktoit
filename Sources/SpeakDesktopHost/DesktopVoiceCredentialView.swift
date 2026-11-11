import Foundation
import SpeakCore

package struct DesktopVoiceCredentialView: Sendable {
    package let requestID: String
    package let selectionEpoch: String
    package let identifier: String
    package let label: String
    package let privacy: String
    package let status: String
    package let saved: Int32
    package let canSave: Int32

    package init(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>,
        requestID: UUID, credentialStore: String
    ) {
        self.requestID = requestID.uuidString
        switch result {
        case .success(let value):
            selectionEpoch = value.selectionEpoch.uuidString
            identifier = value.slot.identifier
            label = value.slot.entryLabel
            privacy = value.slot.privacyDescription
            saved = value.hasSavedKey ? 1 : 0
            canSave = value.canSave ? 1 : 0
            status = (value.hasSavedKey ? "A key is saved in \(credentialStore). It is never shown or prefilled."
                : "No key is saved in \(credentialStore).")
                + (value.canSave ? ""
                    : " Wait for recording, Voice Output and pending key operations, then reopen or recheck key entry.")
        case .failure(let error):
            selectionEpoch = ""
            identifier = ""
            label = "Voice provider key unavailable"
            privacy = "No key is shown or prefilled. This form does not send Voice text or make a provider request."
            status = error.localizedDescription
            saved = -1
            canSave = 0
        }
    }
}

/// The native editor's finished line after a provider key save or removal.
package struct DesktopVoiceCredentialOutcome: Sendable {
    package let success: Int32
    package let message: String

    package init(_ result: Result<Void, VoiceOutputCredentialError>, removing: Bool) {
        switch result {
        case .success:
            success = 1
            message = removing ? "The saved provider key was removed." : "The provider key was saved."
        case .failure(let error):
            success = 0
            message = error.localizedDescription
        }
    }
}
