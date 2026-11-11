#if os(iOS)
import Foundation
import Speech
import SpeakCore

/// The permissions and model readiness Apple Speech capture needs.
enum AppleSpeechReadiness {
    enum Outcome: Equatable {
        case granted
        /// The caller's task was cancelled while a prompt was showing.
        case cancelled
        case denied(iOSTranscriptionError.Permission)
    }

    /// Raised when the SpeechAnalyzer assets are missing and the legacy
    /// recogniser cannot stand in for them.
    static var modelPreparationError: NSError {
        NSError(domain: "AppleSpeechPreparation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Apple's on-device speech model is not ready. "
                + "Open Settings and tap Prepare Apple model, then try again."
        ])
    }

    /// Checks both permissions, prompting for whichever is missing.
    @MainActor
    static func request(using audioSessionManager: AudioSessionManager) async -> Outcome {
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            guard !Task.isCancelled else { return .cancelled }
            if !granted { return .denied(.microphone) }
        }

        guard !Task.isCancelled else { return .cancelled }
        guard SFSpeechRecognizer.authorizationStatus() != .authorized else { return .granted }
        let granted = await CancellablePermissionRequest.request { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status == .authorized)
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        return granted ? .granted : .denied(.speechRecognition)
    }
}
#endif
