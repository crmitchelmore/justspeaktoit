#if os(iOS)
import Foundation
import SpeakCore

/// Errors the iOS batch routes surface to the app and keyboard. Every route
/// maps its provider's failures onto this vocabulary so the UI can name the
/// service and status without knowing which client produced them.
public enum IOSBatchTranscriptionError: LocalizedError {
    case apiKeyMissing
    case missingRecording
    case audioTooLarge
    case invalidResponse
    case emptyTranscript
    case httpError(String, Int, String)
    /// A batch job the provider accepted but could not complete: an
    /// unsupported input, a terminal job failure, or the local polling
    /// deadline. The message is the provider client's own.
    case jobFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "The selected batch model needs an API key."
        case .missingRecording: return "The audio recording could not be saved."
        case .audioTooLarge: return "This recording is too large for OpenRouter's 50 MB upload limit."
        case .invalidResponse: return "The transcription service returned an invalid response."
        case .emptyTranscript: return "The transcription service returned an empty transcript."
        case .httpError(let service, let status, let body):
            return "\(service) returned HTTP \(status): \(body)"
        case .jobFailed(let service, let message):
            return message.isEmpty ? "\(service) could not transcribe the recording." : message
        }
    }
}

extension IOSBatchTranscriptionError {
    /// Translates the shared batch clients' vocabulary into this one, so a
    /// route built on `BatchTranscriptionJob` still emits only the error type
    /// its callers are documented to receive.
    static func from(_ error: BatchTranscriptionJobError, service: String) -> IOSBatchTranscriptionError {
        if case .emptyTranscript = error { return .emptyTranscript }
        return .jobFailed(service, error.errorDescription ?? "")
    }
}

#endif
