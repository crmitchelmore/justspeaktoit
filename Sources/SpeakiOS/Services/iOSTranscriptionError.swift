#if os(iOS)
import Foundation

// swiftlint:disable:next type_name
/// Error types for iOS live transcription.
public enum iOSTranscriptionError: LocalizedError {
    case permissionDenied(Permission)
    case recognizerUnavailable
    case audioSessionFailed(Error)
    case recognitionFailed(Error)
    case interrupted

    public enum Permission {
        case microphone
        case speechRecognition
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(.microphone):
            return "Microphone permission is required for transcription."
        case .permissionDenied(.speechRecognition):
            return "Speech recognition permission is required."
        case .recognizerUnavailable:
            return "Speech recognizer is not available for the selected language."
        case .audioSessionFailed(let error):
            return "Failed to configure audio: \(error.localizedDescription)"
        case .recognitionFailed(let error):
            return "Recognition failed: \(error.localizedDescription)"
        case .interrupted:
            return "Transcription was interrupted (e.g., by a phone call)."
        }
    }
}
#endif
